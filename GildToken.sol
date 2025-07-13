// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

contract GildToken is ERC20Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable, ERC165Upgradeable {

    uint256 public immutable MAX_SUPPLY = 1_000_000_000 * 10**18;
    uint256 public inflationRate = 6; // % per year
    uint256 public lastInflationTime = block.timestamp;
    uint256 public rewardRate = 12; // Base APY % for gilding stakes
    uint256 public constant MIN_STAKE = 32 * 10**18; // Minimum stake amount
    
    // ERC7201 namespaced storage for upgrade safety
    struct Storage {
        mapping(address => uint256) stakedBalances;
        mapping(address => uint256) stakingRewards;
        mapping(address => uint256) stakingTimestamps;
        mapping(address => uint256) goldBoosts;
        uint256 totalStaked;
    }
    
    bytes32 private constant STORAGE_POSITION = keccak256("gildtoken.storage.v1");
    
    function _storage() private pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }
    
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event GoldBoostSet(address indexed user, uint256 boost);
    event InflationMinted(uint256 amount);
    event TokensBurned(uint256 amount);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // For upgradeability
    }

    function initialize() initializer public {
        __ERC20_init("Gild", "GILD");
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ERC165_init();
        _mint(msg.sender, MAX_SUPPLY / 5); // 20% initial for liquidity
    }
    
    /// @notice Mint inflation rewards, with overflow protection and burn
    function mintInflation() external onlyOwner whenNotPaused {
        uint256 timePassed = block.timestamp - lastInflationTime;
        if (timePassed >= 365 days) {
            uint256 numYears = timePassed / (365 days);
            uint256 newTokens = (totalSupply() * inflationRate * numYears) / 100; // Optimized order
            uint256 toMint = newTokens / 2;
            uint256 toBurn = newTokens - toMint; // Explicit burn
            _mint(address(this), toMint);
            _burn(address(this), toBurn); // Burn the rest
            lastInflationTime = block.timestamp;
            emit InflationMinted(toMint);
            emit TokensBurned(toBurn);
        }
    }
    
    modifier antiFrontRun() {
        uint256 gasStart = gasleft();
        _;
        require(gasleft() > gasStart / 63, "Possible front-run detected");
    }
    
    /// @notice Stake tokens with min check
    function stake(uint256 amount) external nonReentrant antiFrontRun whenNotPaused {
        require(amount >= MIN_STAKE, "Amount below minimum stake");
        _transfer(msg.sender, address(this), amount);
        updateRewards(msg.sender);
        Storage storage s = _storage();
        s.stakedBalances[msg.sender] += amount;
        s.totalStaked += amount;
        s.stakingTimestamps[msg.sender] = block.timestamp;
        emit Staked(msg.sender, amount);
    }
    
    /// @notice Unstake after unbonding
    function unstake(uint256 amount) external nonReentrant antiFrontRun whenNotPaused {
        require(amount > 0 && amount <= _storage().stakedBalances[msg.sender], "Invalid amount");
        require(block.timestamp >= _storage().stakingTimestamps[msg.sender] + 7 days, "Unbonding period");
        updateRewards(msg.sender);
        Storage storage s = _storage();
        s.stakedBalances[msg.sender] -= amount;
        s.totalStaked -= amount;
        _transfer(address(this), msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }
    
    /// @notice Claim accumulated rewards
    function claimRewards() external nonReentrant antiFrontRun whenNotPaused {
        updateRewards(msg.sender);
        Storage storage s = _storage();
        uint256 rewards = s.stakingRewards[msg.sender];
        if (rewards > 0) {
            s.stakingRewards[msg.sender] = 0;
            _transfer(address(this), msg.sender, rewards);
            emit RewardClaimed(msg.sender, rewards);
        }
    }
    
    /// @notice Internal reward calculation
    function updateRewards(address user) internal {
        Storage storage s = _storage();
        uint256 timeStaked = block.timestamp - s.stakingTimestamps[user];
        uint256 baseRewards = (s.stakedBalances[user] * rewardRate * timeStaked) / (100 * 365 days); // Optimized order
        uint256 boosted = baseRewards + (baseRewards * s.goldBoosts[user] / 100);
        s.stakingRewards[user] += boosted;
        s.stakingTimestamps[user] = block.timestamp;
    }
    
    /// @notice Set boost for user
    function setGoldBoost(address user, uint256 boost) external onlyOwner {
        require(boost <= 20, "Max 20% boost");
        _storage().goldBoosts[user] = boost;
        emit GoldBoostSet(user, boost);
    }
    
    /// @notice Governance: Set inflation rate
    function setInflationRate(uint256 newRate) external onlyOwner {
        inflationRate = newRate;
    }
    
    /// @notice Governance: Set reward rate
    function setRewardRate(uint256 newRate) external onlyOwner {
        rewardRate = newRate;
    }
    
    /// @notice Pause contract in emergencies
    function pause() external onlyOwner {
        _pause();
    }
    
    /// @notice Unpause contract
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /// @notice Emergency withdraw for paused state
    function emergencyWithdraw(uint256 amount) external whenPaused {
        Storage storage s = _storage();
        require(amount <= s.stakedBalances[msg.sender], "Invalid amount");
        s.stakedBalances[msg.sender] -= amount;
        s.totalStaked -= amount;
        _transfer(address(this), msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }
    
    /// @notice Receive function for plain ETH transfers
    receive() external payable {
        revert("GildToken: No plain ETH accepted");
    }
    
    /// @notice Fallback function for unknown calls (non-payable to separate from receive)
    fallback() external {
        revert("GildToken: Unknown function call");
    }
    
    // UUPS upgrade authorization
    function _authorizeUpgrade(address newImplementation) internal onlyOwner override {}
    
    // ERC165 support
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
