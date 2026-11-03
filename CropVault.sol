// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title CropVault
 * @notice Decentralized crop insurance and yield prediction escrow on Botchain
 * @dev Farmers buy coverage; oracle-triggered payouts on drought/flood events; community staking
 */
contract CropVault {

    // ─── Enums ────────────────────────────────────────────────────────────────
    enum CoverageType  { Drought, Flood, Frost, Pest, Comprehensive }
    enum ClaimStatus   { Pending, Approved, Rejected, Paid }
    enum PolicyStatus  { Active, Expired, Claimed }

    // ─── Structs ──────────────────────────────────────────────────────────────
    struct Policy {
        uint256 id;
        address farmer;
        CoverageType coverageType;
        uint256 cropValueWei;       // declared crop value
        uint256 premiumPaid;        // premium in wei
        uint256 coverageAmount;     // max payout (80% of cropValue)
        uint256 startDate;
        uint256 endDate;
        string  farmLocation;
        string  cropType;
        PolicyStatus status;
    }

    struct Claim {
        uint256 id;
        uint256 policyId;
        address farmer;
        string  description;
        string  evidenceHash;       // IPFS CID of evidence
        uint256 filedAt;
        uint256 requestedAmount;
        ClaimStatus status;
        address assessedBy;
        string  assessorNotes;
    }

    struct Staker {
        uint256 amountStaked;
        uint256 rewardDebt;
        uint256 stakeTime;
    }

    // ─── State ────────────────────────────────────────────────────────────────
    address public owner;
    uint256 public policyCounter;
    uint256 public claimCounter;
    uint256 public totalStaked;
    uint256 public totalCoverage;           // total coverage liability
    uint256 public accRewardPerStake;       // scaled 1e12
    uint256 public premiumPoolBalance;

    // Premium rates in basis points of crop value (annualised)
    mapping(CoverageType => uint256) public premiumRateBps;

    mapping(uint256 => Policy)   public policies;
    mapping(uint256 => Claim)    public claims;
    mapping(address => Staker)   public stakers;
    mapping(address => uint256[]) public farmerPolicies;
    mapping(address => bool)     public assessors;

    // ─── Events ───────────────────────────────────────────────────────────────
    event PolicyCreated(uint256 indexed policyId, address indexed farmer, CoverageType cType, uint256 coverage);
    event ClaimFiled(uint256 indexed claimId, uint256 indexed policyId, address indexed farmer, uint256 requested);
    event ClaimAssessed(uint256 indexed claimId, ClaimStatus status, address assessor);
    event ClaimPaid(uint256 indexed claimId, address indexed farmer, uint256 amount);
    event Staked(address indexed staker, uint256 amount);
    event Unstaked(address indexed staker, uint256 amount, uint256 rewards);
    event OracleEvent(string eventType, string location, uint256 severity);

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyOwner()     { require(msg.sender == owner, "Not owner"); _; }
    modifier onlyAssessor()  { require(assessors[msg.sender] || msg.sender == owner, "Not assessor"); _; }
    modifier policyExists(uint256 _id) { require(_id > 0 && _id <= policyCounter, "Policy not found"); _; }
    modifier claimExists(uint256 _id)  { require(_id > 0 && _id <= claimCounter,  "Claim not found"); _; }

    constructor() {
        owner = msg.sender;
        assessors[msg.sender] = true;

        // Set default premium rates
        premiumRateBps[CoverageType.Drought]       = 300;  // 3%
        premiumRateBps[CoverageType.Flood]         = 250;  // 2.5%
        premiumRateBps[CoverageType.Frost]         = 200;  // 2%
        premiumRateBps[CoverageType.Pest]          = 150;  // 1.5%
        premiumRateBps[CoverageType.Comprehensive] = 600;  // 6%
    }

    // ─── Policy Management ────────────────────────────────────────────────────
    function calculatePremium(
        CoverageType _type,
        uint256 _cropValueWei,
        uint256 _durationDays
    ) public view returns (uint256) {
        uint256 annualPremium = (_cropValueWei * premiumRateBps[_type]) / 10000;
        return (annualPremium * _durationDays) / 365;
    }

    function purchasePolicy(
        CoverageType _coverageType,
        uint256 _cropValueWei,
        uint256 _durationDays,
        string calldata _farmLocation,
        string calldata _cropType
    ) external payable returns (uint256) {
        require(_cropValueWei > 0, "Invalid crop value");
        require(_durationDays >= 30 && _durationDays <= 365, "Duration 30-365 days");

        uint256 premium = calculatePremium(_coverageType, _cropValueWei, _durationDays);
        require(msg.value >= premium, "Insufficient premium");

        uint256 coverage = (_cropValueWei * 80) / 100; // 80% payout cap
        // Ensure vault can cover (simple solvency check)
        require(totalStaked + premiumPoolBalance >= totalCoverage + coverage, "Vault insufficient");

        policyCounter++;
        policies[policyCounter] = Policy({
            id:             policyCounter,
            farmer:         msg.sender,
            coverageType:   _coverageType,
            cropValueWei:   _cropValueWei,
            premiumPaid:    msg.value,
            coverageAmount: coverage,
            startDate:      block.timestamp,
            endDate:        block.timestamp + (_durationDays * 1 days),
            farmLocation:   _farmLocation,
            cropType:       _cropType,
            status:         PolicyStatus.Active
        });

        farmerPolicies[msg.sender].push(policyCounter);
        totalCoverage      += coverage;
        premiumPoolBalance += msg.value;

        // Distribute 70% of premium to stakers
        _distributePremium((msg.value * 70) / 100);

        // Refund excess
        if (msg.value > premium) {
            (bool r,) = payable(msg.sender).call{value: msg.value - premium}("");
            require(r, "Refund failed");
        }

        emit PolicyCreated(policyCounter, msg.sender, _coverageType, coverage);
        return policyCounter;
    }

    // ─── Claims ───────────────────────────────────────────────────────────────
    function fileClaim(
        uint256 _policyId,
        string calldata _description,
        string calldata _evidenceHash,
        uint256 _requestedAmount
    ) external policyExists(_policyId) returns (uint256) {
        Policy storage policy = policies[_policyId];
        require(policy.farmer == msg.sender, "Not your policy");
        require(policy.status == PolicyStatus.Active, "Policy not active");
        require(block.timestamp <= policy.endDate, "Policy expired");
        require(_requestedAmount <= policy.coverageAmount, "Exceeds coverage");

        claimCounter++;
        claims[claimCounter] = Claim({
            id:              claimCounter,
            policyId:        _policyId,
            farmer:          msg.sender,
            description:     _description,
            evidenceHash:    _evidenceHash,
            filedAt:         block.timestamp,
            requestedAmount: _requestedAmount,
            status:          ClaimStatus.Pending,
            assessedBy:      address(0),
            assessorNotes:   ""
        });

        emit ClaimFiled(claimCounter, _policyId, msg.sender, _requestedAmount);
        return claimCounter;
    }

    function assessClaim(
        uint256 _claimId,
        bool _approve,
        string calldata _notes
    ) external onlyAssessor claimExists(_claimId) {
        Claim storage claim = claims[_claimId];
        require(claim.status == ClaimStatus.Pending, "Not pending");

        claim.assessedBy    = msg.sender;
        claim.assessorNotes = _notes;

        if (_approve) {
            claim.status = ClaimStatus.Approved;
            _payClaim(_claimId);
        } else {
            claim.status = ClaimStatus.Rejected;
        }

        emit ClaimAssessed(_claimId, claim.status, msg.sender);
    }

    // ─── Staking ─────────────────────────────────────────────────────────────
    function stake() external payable {
        require(msg.value > 0, "Zero stake");
        Staker storage s = stakers[msg.sender];

        // Harvest before updating
        uint256 pending = _pendingStakerReward(msg.sender);
        if (pending > 0) {
            _safeTransfer(msg.sender, pending);
        }

        s.amountStaked += msg.value;
        s.stakeTime     = block.timestamp;
        s.rewardDebt    = (s.amountStaked * accRewardPerStake) / 1e12;
        totalStaked     += msg.value;

        emit Staked(msg.sender, msg.value);
    }

    function unstake(uint256 _amount) external {
        Staker storage s = stakers[msg.sender];
        require(s.amountStaked >= _amount, "Insufficient stake");
        require(block.timestamp >= s.stakeTime + 7 days, "7-day lock");

        uint256 rewards = _pendingStakerReward(msg.sender);
        s.amountStaked -= _amount;
        s.rewardDebt    = (s.amountStaked * accRewardPerStake) / 1e12;
        totalStaked    -= _amount;

        uint256 payout = _amount + rewards;
        _safeTransfer(msg.sender, payout);
        emit Unstaked(msg.sender, _amount, rewards);
    }

    function pendingStakerReward(address _staker) external view returns (uint256) {
        return _pendingStakerReward(_staker);
    }

    // ─── Oracle Hook (owner only for now, extend with Chainlink/Witnet) ───────
    function reportWeatherEvent(
        string calldata _eventType,
        string calldata _location,
        uint256 _severity  // 0-100
    ) external onlyOwner {
        emit OracleEvent(_eventType, _location, _severity);
        // Future: auto-trigger claims for matching policies in _location
    }

    function addAssessor(address _a) external onlyOwner { assessors[_a] = true; }
    function setPremiumRate(CoverageType _t, uint256 _bps) external onlyOwner { premiumRateBps[_t] = _bps; }

    // ─── Views ───────────────────────────────────────────────────────────────
    function getPolicy(uint256 _id) external view policyExists(_id) returns (Policy memory) { return policies[_id]; }
    function getClaim(uint256 _id)  external view claimExists(_id)  returns (Claim memory)  { return claims[_id]; }
    function getFarmerPolicies(address _f) external view returns (uint256[] memory) { return farmerPolicies[_f]; }

    // ─── Internals ───────────────────────────────────────────────────────────
    function _payClaim(uint256 _claimId) internal {
        Claim storage claim   = claims[_claimId];
        Policy storage policy = policies[claim.policyId];

        uint256 payout = claim.requestedAmount;
        require(address(this).balance >= payout, "Vault illiquid");

        claim.status   = ClaimStatus.Paid;
        policy.status  = PolicyStatus.Claimed;
        totalCoverage -= policy.coverageAmount;
        premiumPoolBalance = premiumPoolBalance > payout ? premiumPoolBalance - payout : 0;

        _safeTransfer(claim.farmer, payout);
        emit ClaimPaid(_claimId, claim.farmer, payout);
    }

    function _distributePremium(uint256 _amount) internal {
        if (totalStaked > 0) {
            accRewardPerStake += (_amount * 1e12) / totalStaked;
        }
    }

    function _pendingStakerReward(address _s) internal view returns (uint256) {
        Staker storage s = stakers[_s];
        return (s.amountStaked * accRewardPerStake) / 1e12 - s.rewardDebt;
    }

    function _safeTransfer(address _to, uint256 _amount) internal {
        (bool ok,) = payable(_to).call{value: _amount}("");
        require(ok, "Transfer failed");
    }

    receive() external payable { premiumPoolBalance += msg.value; }
}
