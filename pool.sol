// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "library.sol";

contract AggregateUpdater {
    IOptionPool [] public pools;
    address public _owner;
    
    constructor() public {
        _owner = msg.sender;
    }
    
    modifier onlyOwner() {
        require(msg.sender == _owner, "AggregateUpdater: need owner");
        _;
    }
    
    /**
     * @dev return the earliest update time from all pools
     */
    function getNextUpdateTime() external view returns (uint) {
        uint nextUpdateTime = block.timestamp + 3600;
        for (uint i=0;i<pools.length;i++) {
            if (pools[i].getNextUpdateTime() < nextUpdateTime) {
                nextUpdateTime = pools[i].getNextUpdateTime();
            }
        }
        return nextUpdateTime;
    }
    
    /**
     * @dev update the expired pools
     */
    function update() external {
        IOptionPool [] memory mempools = pools;
        for (uint i=0;i<mempools.length;i++) {
            if (mempools[i].getNextUpdateTime() < block.timestamp) {
                mempools[i].update();  
            }
        }
    }
    
    function addPool(IOptionPool pool) external onlyOwner {
        pools.push(pool);
    }
}

contract PausablePool is Context{
    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event Paused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event Unpaused(address account);
    
    bool private _poolerPaused;
    bool private _buyerPaused;
    
    /**
     * @dev Modifier to make a function callable only when the pooler is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenPoolerNotPaused() {
        require(!_poolerPaused, "PausablePool: pooler paused");
        _;
    }
   
   /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPoolerPaused() {
        require(_poolerPaused, "PausablePool: pooler not paused");
        _;
    }
    
    /**
     * @dev Modifier to make a function callable only when the buyer is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenBuyerNotPaused() {
        require(!_buyerPaused, "PausablePool: buyer paused");
        _;
    }
    
    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenBuyerPaused() {
        require(_buyerPaused, "PausablePool: buyer not paused");
        _;
    }
    
    /**
     * @dev Returns true if the pooler is paused, and false otherwise.
     */
    function poolerPaused() public view returns (bool) {
        return _poolerPaused;
    }
    
    /**
     * @dev Returns true if the buyer is paused, and false otherwise.
     */
    function buyerPaused() public view returns (bool) {
        return _buyerPaused;
    }
    
   /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The pooler must not be paused.
     */
    function _pausePooler() internal whenPoolerNotPaused {
        _poolerPaused = true;
        emit Paused(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The pooler must be paused.
     */
    function _unpausePooler() internal whenPoolerPaused {
        _poolerPaused = false;
        emit Unpaused(_msgSender());
    }
    
   /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The buyer must not be paused.
     */
    function _pauseBuyer() internal whenBuyerNotPaused {
        _buyerPaused = true;
        emit Paused(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The buyer must be paused.
     */
    function _unpauseBuyer() internal whenBuyerPaused {
        _buyerPaused = false;
        emit Unpaused(_msgSender());
    }
}

/**
 * @title base contract for option pool
 */
abstract contract OptionPoolBase is IOptionPool, PausablePool{
    using SafeERC20 for IERC20;
    using SafeERC20 for IOption;
    using SafeMath for uint;
    using Address for address payable;
    
    uint public collateral; // collaterals in this pool
    
    uint256 internal constant MAX_UINT256 = 2**256 - 1;
    uint256 internal constant PREMIUM_SHARE_MULTIPLIER = 1e18;
    uint256 internal constant USDT_DECIMALS = 1e6;
    uint256 internal constant SIGMA_UPDATE_PERIOD = 3600;
    uint16 internal constant INITIAL_SIGMA = 70;
    uint8 internal constant INITIAL_UTILIZATION_RATE = 50;
    uint8 internal constant INITIAL_MAX_UTILIZATION_RATE = 75;

    mapping (address => uint256) internal _premiumBalance; // tracking pooler's claimable premium
    uint256 public premiumReserve; // platform owned 1% premium

    IOption [] internal _options; // all option contracts
    address internal _owner; // owner of this contract

    IERC20 immutable public USDTContract; // USDT asset contract address
    AggregatorV3Interface public priceFeed; // chainlink price feed
    CDFDataInterface public cdfDataContract; // cdf data contract;

    uint8 public utilizationRate; // utilization rate of the pool in percent
    uint8 public maxUtilizationRate; // max utilization rate of the pool in percent
    uint16 public sigma; // current sigma
    
    uint private _sigmaSoldOptions;  // sum total options sold in a period
    uint private _sigmaTotalOptions; // sum total options issued
    uint private _nextSigmaUpdate; // expected next sigma updating time;
    
    // tracking pooler's collateral with
    // the token contract of the pooler;
    IPoolerToken public poolerTokenContract;
    bool poolerTokenOnce;
    
    // platform management contract
    address public poolManagerContract;
    bool poolManagerOnce;

    // number of options
    uint8 immutable internal _numOptions;

    /**
     * @dev Modifier to make a function callable only buy owner
     */
    modifier onlyOwner() {
        require(msg.sender == _owner, "pool: need owner");
        _;
    }
    
    /**
     * @dev Modifier to make a function callable only buy poolerTokenContract
     */
    modifier onlyPoolerTokenContract() {
        require(msg.sender == address(poolerTokenContract), "restricted");
        _;
    }
    
    /**
     * @dev Modifier to make a function callable only buy pool manager
     */
    modifier onlyPoolManager() {
        require(msg.sender == address(poolManagerContract), "restricted");
        _;
    }

    /**
     * @dev settle debug log
     */
    event SettleLog (string name, uint totalProfit, uint totalOptionSold);
    
    /**
     * @dev sigma update log
     */
    event SigmaUpdate(uint sigma, uint rate);
    
    /**
     * @dev Profits Claiming log
     */
     event ProfitsClaim(address account, uint amount);
     
    /**
     * @dev Premium Claiming log
     */
     event PremiumClaim(address account, uint amount);
    
    /**
     * @dev ownership transfer event log
     */
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev sigma set log
     */
    event SigmaSet(uint sigma);

    /**
     * @dev abstract function for current option supply per slot
     */
    function _slotSupply(uint assetPrice) internal view virtual returns(uint);
    
    /**
     * @dev abstract function to calculate option gain
     */
    function _calcProfits(uint settlePrice, uint strikePrice, uint optionAmount) internal view virtual returns(uint256 gain);
    
    /**
     * @dev abstract function to send back option profits
     */
    function _sendProfits(address payable account, uint256 amount) internal virtual;
    
    /**
     * @dev abstract function to get total pledged collateral
     */
    function _totalPledged() internal view virtual returns (uint);

    constructor(IERC20 USDTContract_, AggregatorV3Interface priceFeed_, CDFDataInterface cdfDataContract_, uint8 numOptions) public {
        _owner = msg.sender;
        USDTContract = USDTContract_;
        priceFeed = priceFeed_;
        cdfDataContract = cdfDataContract_;
        utilizationRate = INITIAL_UTILIZATION_RATE;
        maxUtilizationRate = INITIAL_MAX_UTILIZATION_RATE;
        _nextSigmaUpdate = block.timestamp + SIGMA_UPDATE_PERIOD;
        sigma = INITIAL_SIGMA;
        _numOptions = numOptions;
    }

    /**
     * @dev Returns the owner of this contract
     */
    function owner() external override view returns (address) {
        return _owner;
    }
    
    /**
     * @dev transfer ownership
     */
    function transferOwnership(address newOwner) external override onlyOwner {
        require(newOwner != address(0), "owner zero");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
    
    /**
     *@dev pooler & buyer pausing
     */
    function pausePooler() external override onlyOwner { _pausePooler(); }
    function unpausePooler() external override onlyOwner { _unpausePooler(); }
    function pauseBuyer() external override onlyOwner { _pauseBuyer(); }
    function unpauseBuyer() external override onlyOwner { _unpauseBuyer(); } 

    /**
     * @notice check remaining options for the option contract
     */
    function optionsLeft(IOption optionContract) external override view returns (uint256 optionsleft, uint round) {
        return (optionContract.balanceOf(address(this)), optionContract.getRound());
    }

    /**
     * @notice buy options via USDT, pool receive premium
     */
    function buy(uint amount, IOption optionContract, uint round) external override whenBuyerNotPaused returns(bool) {
        // check option expiry
        require(block.timestamp < optionContract.expiryDate(), "expired");
        // check if option current round is the given round
        require (optionContract.getRound() == round, "round mismatch");
            
        // check remaing options
        require(optionContract.balanceOf(address(this)) >= amount, "soldout");

        // calculate premium cost
        uint premium = premiumCost(amount, optionContract);
        require(premium > 0, "option to buy too less");

        // transfer premium USDTs to this pool
        USDTContract.safeTransferFrom(msg.sender, address(this), premium);

        // transfer options to msg.sender
        optionContract.safeTransfer(msg.sender, amount);

        // credit premium to option contract
        optionContract.addPremium(premium);
        
        // sigma: count sold options
        _sigmaSoldOptions = _sigmaSoldOptions.add(amount);
        
        return true;
    }
    
    /**
     * @dev convert sigma to index, sigma will be rounded to nearest index
     */
    function _sigmaToIndex() private view returns(uint) {
        // sigma to index
        require(sigma >=15 && sigma <=145, "[15,145]");
        uint sigmaIndex = sigma / 5;
        return sigmaIndex;
    }

    /**
     * @notice check option cost for given amount of option
     */
    function premiumCost(uint amount, IOption optionContract) public override view returns(uint) {
        // notice the CDF is already multiplied by cdfDataContract.Amplifier()
        uint cdf = cdfDataContract.CDF(optionContract.getDuration(), _sigmaToIndex());
        // note the price is for 10 ** option decimals
        return amount * optionContract.strikePrice() * cdf  / (10 ** uint(optionContract.decimals())) / cdfDataContract.Amplifier();
    }

    /**
     * @notice list all options
     */
    function listOptions() external override view returns (IOption []memory) {
        return _options;
    }
    
    /**
     * @notice get current utilization rate
     */
    function currentUtilizationRate() external override view returns (uint256) {
        return _totalPledged().mul(100).div(collateral);
    }
    
    /**
     * @notice get next update time
     */
    function getNextUpdateTime() external override view returns (uint) {
        uint nextUpdateTime =_nextSigmaUpdate;
        
        for (uint i = 0;i< _options.length;i++) {
            if (_options[i].expiryDate() < nextUpdateTime) {
                nextUpdateTime = _options[i].expiryDate();
            }
        }

        return nextUpdateTime;
    }

    /**
     * @notice update of options, triggered by anyone periodically
     */
    function update() public override {
        uint assetPrice;

        // create a memory copy of array
        IOption [] memory options = _options;
        
        // settle all options
        for (uint i = 0;i< options.length;i++) {
            if (block.timestamp >= options[i].expiryDate()) { // expired
                // lazy evaluation
                if (assetPrice == 0) {
                    assetPrice = getAssetPrice();
                }
                _settleOption(options[i], assetPrice);
            } else { // mark unexpired by clearning 0
                options[i] = IOption(0);
            }
        }

        // calculate supply for a slot after settlement,
        // notice we must settle options before option reset, otherwise
        // we cannot get a correct slot supply due to COLLATERAL WRITE DOWN
        // when multiple options settles at once.
        if (assetPrice > 0) { // assetPrice non-zero suggests at least one settled option
            uint slotSupply = _slotSupply(assetPrice);
            for (uint i = 0;i < options.length;i++) {
                if (options[i] != IOption(0)) { // we only check expiryDate once, it's expensive.
                    // reset option with new slot supply
                    options[i].resetOption(assetPrice, slotSupply);

                    // sigma: count newly issued options
                    _sigmaTotalOptions = _sigmaTotalOptions.add(options[i].totalSupply());
                }
            }
        }

        // should update sigma while sigma period expires
        if (block.timestamp > _nextSigmaUpdate) {
            updateSigma();
        }
    }

    /**
     * @dev function to update sigma value periodically
     */
    function updateSigma() internal {
        // sigma: metrics updates hourly
        if (_sigmaTotalOptions > 0) {
            uint16 s = sigma;
            // update sigma
            uint rate = _sigmaSoldOptions.mul(100).div(_sigmaTotalOptions);
            
            // sigma range [15, 145]
            if (rate > 90 && s < 145) {
                s += 5;
                emit SigmaUpdate(s, rate);
            } else if (rate < 50 && s > 15) {
                s -= 5;
                emit SigmaUpdate(s, rate);
            }
            
            sigma = s;
        }
        
        // new metrics
        uint sigmaTotalOptions;
        uint sigmaSoldOptions;

        // create a memory copy of array
        IOption [] memory options = _options;
        
        // rebuild sold/total metrics
        for (uint i = 0;i< options.length;i++) {
            // sum all issued options and sold options
            uint supply = options[i].totalSupply();
            uint sold = supply.sub(options[i].balanceOf(address(this)));
            
            sigmaTotalOptions = sigmaTotalOptions.add(supply);
            sigmaSoldOptions = sigmaSoldOptions.add(sold);
        }
        
        // set back to contract storage
        _sigmaTotalOptions = sigmaTotalOptions;
        _sigmaSoldOptions = sigmaSoldOptions;
        
        // set next update time to one hour later
        _nextSigmaUpdate = block.timestamp + SIGMA_UPDATE_PERIOD;
    }
    
    /**
     * @notice adjust sigma manually
     */
    function adjustSigma(uint16 newSigma) external override onlyOwner {
        require (newSigma % 5 == 0, "needs 5*N");
        require (newSigma >= 15 && newSigma <= 145, "[15,145]");
        
        sigma = newSigma;
        
        emit SigmaSet(sigma);
    }

    /**
     * @notice pool manager claim 1% premium
     */
    function claimManagerPremium() external override onlyPoolManager {
        uint reserve = premiumReserve;
        premiumReserve = 0; // zero premium balance
        
        // trasnfer premium
        USDTContract.safeTransfer(msg.sender, reserve);
    }
    
    /**
     * @notice poolers claim premium USDTs;
     */
    function claimPremium() external override whenPoolerNotPaused {
        claimPremiumForRounds(MAX_UINT256);
    }
    
    /**
     * @notice poolers claim premium USDTs for num rounds.
     */
    function claimPremiumForRounds(uint numRounds) public override whenPoolerNotPaused {
        // settle un-distributed premiums in rounds to _premiumBalance;
        _settlePremium(msg.sender, numRounds);

        // premium balance modification
        uint amountUSDTPremium = _premiumBalance[msg.sender];
        _premiumBalance[msg.sender] = 0; // zero premium balance
        
        // trasnfer premium
        USDTContract.safeTransfer(msg.sender, amountUSDTPremium);
        
        // log
        emit PremiumClaim(msg.sender, amountUSDTPremium);
    }
    
    /**
     * @notice settle premium in rounds while pooler token transfers.
     */
    function settlePremiumByPoolerToken(address account) external override onlyPoolerTokenContract {
        _settlePremium(account, MAX_UINT256);
    }
    
    /**
     * @dev settle option contract
     */
    function _settleOption(IOption option, uint settlePrice) internal {
        uint totalSupply = option.totalSupply();
        uint strikePrice = option.strikePrice();
        
        // count total sold options
        uint totalOptionSold = totalSupply.sub(option.balanceOf(address(this)));
        
        // calculate total gain
        uint totalProfits = _calcProfits(settlePrice, strikePrice, totalOptionSold);

        // substract collateral
        // buyer's gain is pooler's loss
        collateral = collateral.sub(totalProfits);

        // settle preimum dividends
        uint poolerTotalSupply = poolerTokenContract.totalSupply();
        uint totalPremiums = option.totalPremiums();
        
        if (poolerTotalSupply > 0) {
            // 1% belongs to platform
            uint reserve = totalPremiums.div(100);
            premiumReserve = premiumReserve.add(reserve);
            
            // 99% belongs to all pooler
            uint premiumShare = totalPremiums.sub(reserve)
                                .mul(PREMIUM_SHARE_MULTIPLIER)      // mul share with PREMIUM_SHARE_MULTIPLIER to prevent from underflow
                                .div(poolerTotalSupply);
                                
            // set premium share to round for poolers
            // ASSUMPTION:
            //  if one pooler's token amount keeps unchanged after settlement, then
            //      premiumShare * (pooler token) 
            //  is the share for one pooler.
            option.setRoundPremiumShare(option.getRound(), premiumShare);
        }
        
        // log
        emit SettleLog(option.name(), totalProfits, totalOptionSold);
    }
    
    /**
     * @notice settle premium in rounds to _premiumBalance, 
     * settle premium happens before any token exchange such as ERC20-transfer,mint,burn,
     * and manually claimPremium;
     * 
     * @return false means the rounds has terminated due to round limit
     */
    function _settlePremium(address account, uint numRounds) internal returns(bool) {
        uint accountCollateral = poolerTokenContract.balanceOf(account);
        // create a memory copy of array
        IOption [] memory options = _options;
        
        // at any time we find a pooler with 0 collateral, we can mark the previous rounds settled
        // to avoid meaningless round loops below.
        if (accountCollateral == 0) {
            for (uint i = 0; i < options.length; i++) {
                if (options[i].getRound() > 0) {
                    // all settled rounds before current round marked settled, which also means
                    // new collateral will make money immediately at current round.
                    options[i].setSettledPremiumRound(options[i].getRound() - 1, account);
                }
            }
            return true;
        }
        
        // at this stage, the account has collaterals
        uint roundsCounter;
        uint premiumBalance = _premiumBalance[account];
        
        for (uint i = 0; i < options.length; i++) {
            IOption option = options[i];
            
            // shift premium from settled rounds with rounds control
            uint maxRound = option.getRound();
            uint lastSettledRound = option.getSettledPremiumRound(account);
            
            for (uint r = lastSettledRound + 1; r < maxRound; r++) {
                uint roundPremium = option.getRoundPremiumShare(r)
                                            .mul(accountCollateral)
                                            .div(PREMIUM_SHARE_MULTIPLIER);  // remember to div by PREMIUM_SHARE_MULTIPLIER

                // add to local balance variable
                premiumBalance = premiumBalance.add(roundPremium);
                
                // record last settled round
                lastSettledRound = r;

                // @dev BLOCK GAS LIMIT PROBLEM
                // poolers needs to submit multiple transactions to claim ALL premiums in all rounds
                // due to gas limit.
                roundsCounter++;
                if (roundsCounter >= numRounds) {
                    // mark max round premium claimed and return.
                    option.setSettledPremiumRound(lastSettledRound, account);
                    // set back balance to storage
                    _premiumBalance[account] = premiumBalance;
                    return false;
                }
            }
            
            // mark max round premium claimed and proceed.
            option.setSettledPremiumRound(lastSettledRound, account);
        }

        // set back balance to storage
        _premiumBalance[account] = premiumBalance;
        return true;
    }

    /**
     * @notice net-withdraw amount;
     */
    function NWA() public view override returns (uint) {
        // get minimum collateral
        uint minCollateral = _totalPledged() * 100 / maxUtilizationRate;
        if (minCollateral > collateral) {
            return 0;
        }

        // net withdrawable amount
        return collateral.sub(minCollateral);
    }
    
    /**
     * @notice poolers sum premium USDTs;
     */
    function checkPremium(address account) external override view returns(uint256 premium, uint numRound) {
        uint accountCollateral = poolerTokenContract.balanceOf(account);

        // if the account has 0 value pooled
        if (accountCollateral == 0) {
            return (0, 0);
        }
        
        premium = _premiumBalance[account];
        
        for (uint i = 0; i < _options.length; i++) {
            IOption option = _options[i];
            uint maxRound = option.getRound();
            
            for (uint r = option.getSettledPremiumRound(account) + 1; r < maxRound; r++) {
                uint roundPremium = option.getRoundPremiumShare(r)
                                            .mul(accountCollateral)
                                            .div(PREMIUM_SHARE_MULTIPLIER);  // remember to div by PREMIUM_SHARE_MULTIPLIER
                    
                premium = premium.add(roundPremium);
                numRound++;
            }
        }
        
        return (premium, numRound);
    }
    
    /**
     * @notice buyers claim option profits
     */   
    function claimProfits() external override whenBuyerNotPaused {
        uint accountProfits;
        
        // create a memory copy of array
        IOption [] memory options = _options;
        
        // sum all profits from all options
        for (uint i = 0; i < options.length; i++) {
            IOption option = options[i];
            
            // check option profits
            (uint optionProfits,) = checkOptionProfits(option, msg.sender);
            accountProfits = accountProfits.add(optionProfits);
            
            // clear unclaimed rounds(claimed)
            option.clearUnclaimedProfitsRounds(msg.sender);
        }
        
        // send profits
        _sendProfits(msg.sender, accountProfits);
        
        // log
        emit ProfitsClaim(msg.sender, accountProfits);
    }
    
    /**
     * @notice check claimable buyer's profits
     */
    function checkProfits(address account) external override view returns (uint256 profits, uint numRound) {
        // sum all profits from all options
        for (uint i = 0; i < _options.length; i++) {
            (uint optionProfits, uint optionRounds) = checkOptionProfits(_options[i], account);
            profits = profits.add(optionProfits);
            numRound = numRound.add(optionRounds);
        }
        
        return (profits, numRound);
    }
    
    /**
     * @notice check profits in an option
     */
    function checkOptionProfits(IOption option, address account) internal view returns (uint256 amount, uint numRound) {
        // get unsettled round 
        uint unsettledRound = option.getRound();
        
        // sum all profits from all un-claimed rounds
        uint [] memory rounds  = option.getUnclaimedProfitsRounds(account);
        for (uint i=0;i<rounds.length;i++) {
            // remember to exclude the current unsettled round
            if (rounds[i] == unsettledRound) {
                continue;
            }
            
            uint settlePrice = option.getRoundSettlePrice(rounds[i]);
            uint strikePrice = option.getRoundStrikePrice(rounds[i]);
            uint optionAmount = option.getRoundBalanceOf(rounds[i], account);
            
            // accumulate gain in rounds    
            amount = amount.add(_calcProfits(settlePrice, strikePrice, optionAmount));
            
            // accumulate rounds
            numRound++;
        }
        return (amount, numRound);
    }

    /**
     * @notice set new option contract to option pool with different duration
     */
    function setOption(IOption option) external override onlyOwner {
        require(_options.length <= _numOptions, "options exceeded");
        require(option.getDuration() > 0, "duration is 0");
        require(option.totalSupply() == 0, "totalSupply != 0");
        require(option.getPool() == address(this), "owner mismatch");
        
        // the duration must be in the set
        bool durationValid;
        for (uint i=0;i<cdfDataContract.numDurations();i++) {
            if (option.getDuration() == cdfDataContract.Durations(i)) {
                durationValid = true;
                break;
            }
        }
        require (durationValid, "duration invalid");

        // the option must not be set more than once
        for (uint i = 0;i< _options.length;i++) {
            require(_options[i] != option, "duplicated");
        }
        _options.push(option);
    }
     
    /**
     * @notice set pool manager once(OPA DAO)
     */
    function setPoolManager(address poolManager) external override onlyOwner {
        require (!poolManagerOnce, "already set");
        poolManagerContract = poolManager;
        poolManagerOnce = true;
    }
    
    /**
     * @notice set pooler token once
     */
    function setPoolerToken(IPoolerToken poolerToken) external override onlyOwner {
        require (!poolerTokenOnce, "already set");
        require(poolerToken.getPool() == address(this), "owner mismatch");
        poolerTokenContract = poolerToken;
        poolerTokenOnce = true;
    }
    
    /**
     * @notice set utilization rate by owner
     */
    function setUtilizationRate(uint8 rate) external override onlyOwner {
        require(rate >=0 && rate <= 100, "[0,100]");
        utilizationRate = rate;
    }
    
    /**
     * @notice set max utilization rate by owner
     */
    function setMaxUtilizationRate(uint8 maxrate) external override onlyOwner {
        require(maxrate >=0 && maxrate <= 100, "[0,100]");
        require(maxrate > utilizationRate, "less than rate");
        maxUtilizationRate = maxrate;
    }
    
        
    /**
     * @dev get the price for asset with regarding to asset decimals
     * Example:
     *  for ETH price oracle, this function returns the USDT price for 1 ETH
     */
    function getAssetPrice() public view returns(uint) {
        (, int latestPrice, , , ) = priceFeed.latestRoundData();

        if (latestPrice > 0) { // convert to USDT decimal
            return uint(latestPrice).mul(USDT_DECIMALS).div(10**uint(priceFeed.decimals()));
        }
        return 0;
    }
}

/**
 * @title Implementation of ETH Call Option Pool
 * ETHCallOptionPool Call Option Pool use Ethers as collateral and bets
 * on Chainlink Oralce Price Feed.
 */
contract ETHCallOptionPool is OptionPoolBase {
    /**
     * @param USDTContract Tether USDT contract address
     * @param priceFeed Chainlink contract for getting Ether price
     */
    constructor(IERC20 USDTContract,  AggregatorV3Interface priceFeed, CDFDataInterface cdfContract, uint8 numOptions)
        OptionPoolBase(USDTContract, priceFeed, cdfContract, numOptions)
        public { }

    /**
     * @dev Returns the pool of the contract.
     */
    function name() public pure returns (string memory) {
        return "ETH CALL POOL";
    }

    /**
     * @notice deposit ethers to this pool directly.
     */
    function depositETH() external whenPoolerNotPaused payable {
        require(msg.value > 0, "0 value");
        poolerTokenContract.mint(msg.sender, msg.value);
        collateral = collateral.add(msg.value);
    }
    
    /**
     * @notice withdraw the pooled ethers;
     */
    function withdrawETH(uint amountETH) external whenPoolerNotPaused {
        require (amountETH <= poolerTokenContract.balanceOf(msg.sender), "balance exceeded");
        require (amountETH <= NWA(), "collateral exceeded");

        // burn pooler token
        poolerTokenContract.burn(msg.sender, amountETH);
        // substract collateral
        collateral = collateral.sub(amountETH);

        // transfer ETH to msg.sender
        msg.sender.sendValue(amountETH);
    }
        
    /**
     * @notice sum total collaterals pledged
     */
    function _totalPledged() internal view override returns (uint amount) {
        for (uint i = 0;i< _options.length;i++) {
            amount += _options[i].totalSupply();
        }
    }
    
    /**
     * @dev function to calculate option gain
     */
    function _calcProfits(uint settlePrice, uint strikePrice, uint optionAmount) internal view override returns(uint256 gain) {
        // call options get profits due to price rising.
        if (settlePrice > strikePrice && strikePrice > 0) { 
            // calculate ratio
            uint ratio = settlePrice.sub(strikePrice)
                                        .mul(1e12)              // mul by 1e12 here to prevent from underflow
                                        .div(strikePrice);
            
            // calculate ETH gain of this amount
            uint holderETHProfit = ratio.mul(optionAmount)
                                        .div(1e12);         // remember to div by 1e12 previous mul-ed
            
            return holderETHProfit;
        }
    }

    /**
     * @dev send profits back to sender's address
     */
    function _sendProfits(address payable account, uint256 amount) internal override {
        account.sendValue(amount);
    }
    
    /**
     * @dev get current new option supply
     */
    function _slotSupply(uint) internal view override returns(uint) {
        return collateral.mul(utilizationRate)
                            .div(100)
                            .div(_numOptions);
    }
}

/**
 * @title Implementation of ERC20 Asset Call Option Pool
 * ERC20 Asset Call Option Pool use ERC20 asset as collateral and bets
 * on Chainlink Oralce Price Feed.
 */
contract ERC20CallOptionPool is OptionPoolBase {
    string private _name;
    IERC20 public AssetContract;

    /**
     * @param USDTContract Tether USDT contract address
     * @param priceFeed Chainlink contract for getting Ether price
     */
    constructor(string memory name_, IERC20 AssetContract_, IERC20 USDTContract,  AggregatorV3Interface priceFeed, CDFDataInterface cdfContract, uint8 numOptions)
        OptionPoolBase(USDTContract, priceFeed, cdfContract, numOptions)
        public { 
             _name = name_;
             AssetContract = AssetContract_;
        }

    /**
     * @dev Returns the pool of the contract.
     */
    function name() public view returns (string memory) {
        return _name;
    }
    
    /**
     * @notice deposit asset to this pool directly.
     */
    function depositAsset(uint256 amount) external whenPoolerNotPaused {
        require(amount > 0, "0 value");
        AssetContract.safeTransferFrom(msg.sender, address(this), amount);
        poolerTokenContract.mint(msg.sender, amount);
        collateral = collateral.add(amount);
    }

    /**
     * @notice withdraw the pooled ethers;
     */
    function withdrawAsset(uint amount) external whenPoolerNotPaused {
        require (amount <= poolerTokenContract.balanceOf(msg.sender), "balance exceeded");
        require (amount <= NWA(), "collateral exceeded");

        // burn pooler token
        poolerTokenContract.burn(msg.sender, amount);
        // substract collateral
        collateral = collateral.sub(amount);

        // transfer asset back to msg.sender
        AssetContract.safeTransfer(msg.sender, amount);
    }
        
    /**
     * @notice sum total collaterals pledged
     */
    function _totalPledged() internal view override returns (uint amount) {
        for (uint i = 0;i< _options.length;i++) {
            amount += _options[i].totalSupply();
        }
    }

    /**
     * @dev send profits back to account
     */
    function _sendProfits(address payable account, uint256 amount) internal override {
        AssetContract.safeTransfer(account, amount);
    }

    /**
     * @dev function to calculate option gain
     */
    function _calcProfits(uint settlePrice, uint strikePrice, uint optionAmount) internal view override returns(uint256 gain) {
        // call options get profits due to price rising.
        if (settlePrice > strikePrice && strikePrice > 0) { 
            // calculate ratio
            uint ratio = settlePrice.sub(strikePrice)
                                    .mul(1e12)          // mul by 1e12 here to prevent from underflow
                                    .div(strikePrice);
            
            // calculate Asset gain of this amount
            uint holderAssetProfit = ratio.mul(optionAmount)
                                    .div(1e12);         // remember to div by 1e12 previous mul-ed
            
            return holderAssetProfit;
        }
    }

    /**
     * @notice get current new option supply
     */
    function _slotSupply(uint) internal view override returns(uint) {
        return collateral.mul(utilizationRate)
                            .div(100)
                            .div(_numOptions);
    }
}

/**
 * @title Implementation of Put Option Pool
 * Put Option Pool requires USDT as collateral and 
 * bets on Chainlink Oralce Price Feed of one asset.
 */
contract PutOptionPool is OptionPoolBase {
    string private _name;
    uint private immutable ASSET_PRICE_UNIT;
    
    /**
     * @param USDTContract Tether USDT contract address
     * @param priceFeed Chainlink contract for getting Ether price
     */
    constructor(string memory name_, uint8 assetDecimal, IERC20 USDTContract, AggregatorV3Interface priceFeed, CDFDataInterface cdfContract, uint8 numOptions)
        OptionPoolBase(USDTContract, priceFeed, cdfContract, numOptions)
        public { 
            _name = name_;
            ASSET_PRICE_UNIT = 10 ** uint(assetDecimal);
        }

    /**
     * @dev Returns the pool of the contract.
     */
    function name() public view returns (string memory) {
        return _name;
    }

    /**
     * @notice deposit of Tether USDTS, user needs
     * to approve() to this contract address first,
     * and call with the given amount.
     */
    function depositUSDT(uint256 amountUSDT) external whenPoolerNotPaused {
        require(amountUSDT > 0, "0 value");
        USDTContract.safeTransferFrom(msg.sender, address(this), amountUSDT);
        poolerTokenContract.mint(msg.sender, amountUSDT);
        collateral = collateral.add(amountUSDT);
    }
    
    /**
     * @notice withdraw the pooled USDT;
     */
    function withdrawUSDT(uint amountUSDT) external whenPoolerNotPaused {
        require (amountUSDT <= poolerTokenContract.balanceOf(msg.sender), "balance exceeded");
        require (amountUSDT <= NWA(), "collateral exceeded");

        // burn pooler token
        poolerTokenContract.burn(msg.sender, amountUSDT);
        // substract collateral
        collateral = collateral.sub(amountUSDT);

        // transfer USDT to msg.sender
        USDTContract.safeTransfer(msg.sender, amountUSDT);
    }
    
    /**
     * @notice sum total collaterals pledged
     */
    function _totalPledged() internal view override returns (uint) {
        // sum total collateral in USDT
        uint total;
        for (uint i = 0;i< _options.length;i++) {
            // derive collaterals at issue time
            total = total.add(_options[i].totalSupply() * _options[i].strikePrice());
        }
        
        // @dev remember to div with asset price unit
        total /= ASSET_PRICE_UNIT;        
        return total;
    }

    /**
     * @dev send profits back to account
     */
    function _sendProfits(address payable account, uint256 amount) internal override {
        USDTContract.safeTransfer(account, amount);
    }

    /**
     * @dev function to calculate option gain
     */
    function _calcProfits(uint settlePrice, uint strikePrice, uint optionAmount) internal view override returns(uint256 gain) {
        if (settlePrice < strikePrice && strikePrice > 0) {  // put option get profits at this round
            // calculate ratio
            uint ratio = strikePrice.sub(settlePrice)
                                    .mul(1e12)                  // mul 1e12 to prevent from underflow
                                    .div(strikePrice);

            // holder share
            uint holderShare = ratio.mul(optionAmount);

         
            // convert to USDT gain
            uint holderUSDTProfit = holderShare.mul(strikePrice)
                                    .div(1e12)                  // remember to div 1e12 previous multipied
                                    .div(ASSET_PRICE_UNIT);     // remember to div price unit

            return holderUSDTProfit;
        }
    }

    /**
     * @notice get current new option supply
     */
    function _slotSupply(uint assetPrice) internal view override returns(uint) {
        // reset the contract
        // Formula : (collateral / numOptions) * utilizationRate / 100 / (assetPrice/ price unit)
       return collateral.mul(utilizationRate)
                            .mul(ASSET_PRICE_UNIT)
                            .div(100)
                            .div(_numOptions)
                            .div(assetPrice);
    }
}
