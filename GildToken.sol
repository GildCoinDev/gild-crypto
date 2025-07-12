// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

contract GildToken is 
    ERC20Upgradeable, 
    OwnableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable, 
    UUPSUpgradeable, 
    ERC165Upgradeable 
{
    using SafeMathUpgradeable for uint256;

    /// @dev Constants
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18;
    uint256 public constant MIN_STAKE = 32 * 10**18;

    /// @dev Inflation and staking parameters
    uint256 public inflationRate; // % per year
    uint256 public lastInflationTime;
    uint256 public rewardRate; // Base APY %

    /// @dev Staking state
    mapping(address => uint256) public stakedBalances;
    mapping(address => uint256) public stakingRewards;
    mapping(address => uint256) public stakingTimestamps;
    mapping(address => uint256) public goldBoosts;
    uint256 public totalStaked;

    /// @dev Events
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event GoldBoostSet(address indexed user, uint256 boost);
    event InflationMinted(uint256 amount);
    event TokensBurned(uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __ERC20_init("Gild", "GILD");
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ERC165_init();

        inflationRate = 6;
        rewardRate = 12;
        lastInflationTime = block.timestamp;

        _mint(msg.sender, MAX_SUPPLY / 5); // 20% for liquidity
    }

    modifier antiFrontRun() {
        uint256 gasStart = gasleft();
        _;
        require(gasleft() > gasStart / 63, "Possible front-run detected");
    }

    function stake(uint256 amount) external nonReentrant antiFrontRun whenNotPaused {
        require(amount >= MIN_STAKE, "Amount below minimum stake");
        _transfer(msg.sender, address(this), amount);
        updateRewards(msg.sender);
        stakedBalances[msg.sender] = stakedBalances[msg.sender].add(amount);
        totalStaked = totalStaked.add(amount);
        stakingTimestamps[msg.sender] = block.timestamp;
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant antiFrontRun whenNotPaused {
        require(amount > 0 && amount <= stakedBalances[msg.sender], "Invalid amount");
        require(block.timestamp >= stakingTimestamps[msg.sender] + 7 days, "Unbonding period");
        updateRewards(msg.sender);
        stakedBalances[msg.sender] = stakedBalances[msg.sender].sub(amount);
        totalStaked = totalStaked.sub(amount);
        _transfer(address(this), msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claimRewards() external nonReentrant antiFrontRun whenNotPaused {
        updateRewards(msg.sender);
        uint256 rewards = stakingRewards[msg.sender];
        require(rewards > 0, "No rewards");
        stakingRewards[msg.sender] = 0;
        _transfer(address(this), msg.sender, rewards);
        emit RewardClaimed(msg.sender, rewards);
    }

    function updateRewards(address user) internal {
        uint256 timeStaked = block.timestamp - stakingTimestamps[user];
        uint256 baseRewards = stakedBalances[user]
            .mul(rewardRate)
            .mul(timeStaked)
            .div(100 * 365 days);
        uint256 boosted = baseRewards.add(baseRewards.mul(goldBoosts[user]).div(100));
        stakingRewards[user] = stakingRewards[user].add(boosted);
        stakingTimestamps[user] = block.timestamp;
    }

    function mintInflation() external onlyOwner whenNotPaused {
        uint256 timePassed = block.timestamp - lastInflationTime;
        if (timePassed >= 365 days) {
            uint256 numYears = timePassed / (365 days); // <-- fixed from `years`
            uint256 newTokens = totalSupply().mul(inflationRate).mul(numYears).div(100);
            uint256 toMint = newTokens.div(2);
            uint256 toBurn = newTokens.sub(toMint);
            _mint(address(this), toMint);
            _burn(address(this), toBurn);
            lastInflationTime = block.timestamp;
            emit InflationMinted(toMint);
            emit TokensBurned(toBurn);
        }
    }

    function setGoldBoost(address user, uint256 boost) external onlyOwner {
        require(boost <= 20, "Max 20% boost");
        goldBoosts[user] = boost;
        emit GoldBoostSet(user, boost);
    }

    function setInflationRate(uint256 newRate) external onlyOwner {
        inflationRate = newRate;
    }

    function setRewardRate(uint256 newRate) external onlyOwner {
        rewardRate = newRate;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(uint256 amount) external whenPaused {
        require(amount <= stakedBalances[msg.sender], "Invalid amount");
        stakedBalances[msg.sender] = stakedBalances[msg.sender].sub(amount);
        totalStaked = totalStaked.sub(amount);
        _transfer(address(this), msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    receive() external payable {
        revert("GildToken: No plain ETH accepted");
    }

    fallback() external {
        revert("GildToken: Unknown function call");
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
