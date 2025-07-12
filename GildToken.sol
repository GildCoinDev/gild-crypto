pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract GildToken is ERC20, Ownable, ReentrancyGuard {
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18;
    uint256 public inflationRate = 6; // % per year
    uint256 public lastInflationTime = block.timestamp;
    uint256 public rewardRate = 12; // Base APY % for gilding stakes
    
    mapping(address => uint256) public stakedBalances;
    mapping(address => uint256) public stakingRewards;
    mapping(address => uint256) public stakingTimestamps;
    mapping(address => uint256) public goldBoosts; // Gold lock boosts (veGILD)
    
    uint256 public totalStaked;
    
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event GoldBoostSet(address indexed user, uint256 boost);
    
    constructor() ERC20("Gild", "GILD") {
        _mint(msg.sender, MAX_SUPPLY / 5); // 20% initial for liquidity
    }
    
    // Inflation minting (governance callable)
    function mintInflation() external onlyOwner {
        uint256 timePassed = block.timestamp - lastInflationTime;
        if (timePassed >= 365 days) {
            uint256 years = timePassed / 365 days;
            uint256 newTokens = (totalSupply() * inflationRate * years) / 100;
            _mint(address(this), newTokens / 2); // 50% to contract, burn rest implicitly
            lastInflationTime = block.timestamp;
        }
    }
    
    // Stake function: Gild your tokens
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be positive");
        _transfer(msg.sender, address(this), amount);
        updateRewards(msg.sender);
        stakedBalances[msg.sender] += amount;
        totalStaked += amount;
        stakingTimestamps[msg.sender] = block.timestamp;
        emit Staked(msg.sender, amount);
    }
    
    // Unstake (with unbonding simulation via delay)
    function unstake(uint256 amount) external nonReentrant {
        require(amount > 0 && amount <= stakedBalances[msg.sender], "Invalid amount");
        require(block.timestamp >= stakingTimestamps[msg.sender] + 7 days, "Unbonding period");
        updateRewards(msg.sender);
        stakedBalances[msg.sender] -= amount;
        totalStaked -= amount;
        _transfer(address(this), msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }
    
    // Claim rewards: Harvest gilded yields
    function claimRewards() external nonReentrant {
        updateRewards(msg.sender);
        uint256 rewards = stakingRewards[msg.sender];
        if (rewards > 0) {
            stakingRewards[msg.sender] = 0;
            _transfer(address(this), msg.sender, rewards);
            emit RewardClaimed(msg.sender, rewards);
        }
    }
    
    // Internal reward update with goldBoost
    function updateRewards(address user) internal {
        uint256 timeStaked = block.timestamp - stakingTimestamps[user];
        uint256 baseRewards = (stakedBalances[user] * rewardRate * timeStaked) / (100 * 365 days);
        uint256 boosted = baseRewards + (baseRewards * goldBoosts[user]) / 100;
        stakingRewards[user] += boosted;
        stakingTimestamps[user] = block.timestamp;
    }
    
    // Set goldBoost (governance or lock function)
    function setGoldBoost(address user, uint256 boost) external onlyOwner {
        require(boost <= 20, "Max 20% boost");
        goldBoosts[user] = boost;
        emit GoldBoostSet(user, boost);
    }
    
    // Governance setters
    function setInflationRate(uint256 newRate) external onlyOwner {
        inflationRate = newRate;
    }
    
    function setRewardRate(uint256 newRate) external onlyOwner {
        rewardRate = newRate;
    }
}
