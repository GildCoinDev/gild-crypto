// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

contract GildToken is ERC20Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable, ERC165Upgradeable {
    using SafeMathUpgradeable for uint256;

    uint256 public immutable MAX_SUPPLY = 1_000_000_000 * 10**18;
    uint256 public inflationRate = 6; // % per year
    uint256 public lastInflationTime = block.timestamp;
    uint256 public rewardRate = 12; // Base APY % for gilding stakes
    uint256 public constant MIN_STAKE = 32 * 10**18; // Minimum stake amount
    
    mapping(address => uint256) public stakedBalances;
    mapping(address => uint256) public stakingRewards;
    mapping(address => uint256) public stakingTimestamps;
    mapping(address => uint256) public goldBoosts; // Gold lock boosts (veGILD)
    
    uint256 public totalStaked;
    
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
            uint256 newTokens = totalSupply().mul(inflationRate).mul(numYears).div(100);
            uint256 toMint = newTokens.div(2);
            uint256 toBurn = newTokens.sub(toMint); // Explicit burn
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
        stakedBalances[msg.sender] = stakedBalances[msg.sender].add(amount);
        totalStaked = totalStaked.add(amount);
        stakingTimestamps[msg.sender] = block.timestamp;
        emit Staked(msg.sender, amount);
    }
    
    /// @notice Unstake after unbonding
    function unstake(uint256 amount) external nonReentrant antiFrontRun whenNotPaused {
        require(amount > 0 && amount <= stakedBalances[msg.sender], "Invalid amount");
        require(block.timestamp >= stakingTimestamps[msg.sender] + 7 days, "Unbonding period");
        updateRewards(msg.sender);
        stakedBalances[msg.sender] = stakedBalances[msg.sender].sub(amount);
        totalStaked = totalStaked.sub(amount);
        _transfer(address(this), msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }
    
    /// @notice Claim accumulated rewards
    function claimRewards() external nonReentrant antiFrontRun whenNotPaused {
        updateRewards(msg.sender);
        uint256 rewards = stakingRewards[msg.sender];
        if (rewards > 0) {
            stakingRewards[msg.sender] = 0;
            _transfer(address(this), msg.sender, rewards);
            emit RewardClaimed(msg.sender, rewards);
        }
    }
    
    /// @notice Internal reward calculation
    function updateRewards(address user) internal {
        uint256 timeStaked = block.timestamp - stakingTimestamps[user];
        uint256 baseRewards = stakedBalances[user].mul(rewardRate).mul(timeStaked).div(100 * 365 days);
        uint256 boosted = baseRewards.add(baseRewards.mul(goldBoosts[user]).div(100));
        stakingRewards[user] = stakingRewards[user].add(boosted);
        stakingTimestamps[user] = block.timestamp;
    }
    
    /// @notice Set boost for user
    function setGoldBoost(address user, uint256 boost) external onlyOwner {
        require(boost <= 20, "Max 20% boost");
        goldBoosts[user] = boost;
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
        require(amount <= stakedBalances[msg.sender], "Invalid amount");
        stakedBalances[msg.sender] = stakedBalances[msg.sender].sub(amount);
        totalStaked = totalStaked.sub(amount);
        _transfer(address(this), msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }
    
    // UUPS upgrade authorization
    function _authorizeUpgrade(address newImplementation) internal onlyOwner override {}
    
    // ERC165 support
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
