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
    
    function update() external {
        for (uint i=0;i<pools.length;i++) {
            pools[i].update();
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
    uint256 internal constant PREMIUM_SHARE_MULTIPLIER = 1e18;
    uint256 internal constant USDT_DECIMALS = 1e6;
    
    mapping (address => uint256) internal _premiumBalance; // tracking pooler's claimable premium

    IOption [] internal _options; // all option contracts
    address internal _owner; // owner of this contract

    IERC20 immutable public USDTContract; // USDT asset contract address
    AggregatorV3Interface public priceFeed; // chainlink price feed
    CDFDataInterface public cdfDataContract; // cdf data contract;

    uint public utilizationRate; // utilization rate of the pool in percent
    uint public maxUtilizationRate; // max utilization rate of the pool in percent
    uint64 public sigma; // current sigma
    
    uint private _sigmaSoldOptions;  // sum total options sold in a period
    uint private _sigmaTotalOptions; // sum total options issued
    uint private _nextSigmaUpdate; // expected next sigma updating time;
    
    // tracking pooler's collateral with
    // the token contract of the pooler;
    IPoolerToken public poolerTokenContract;
    bool poolerTokenOnce;

    // number of options
    uint immutable internal _numOptions;

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
        require(msg.sender == address(poolerTokenContract), "pool: need poolerTokenContract");
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

    constructor(IERC20 USDTContract_, AggregatorV3Interface priceFeed_, CDFDataInterface cdfDataContract_, uint numOptions) public {
        _owner = msg.sender;
        USDTContract = USDTContract_;
        priceFeed = priceFeed_;
        cdfDataContract = cdfDataContract_;
        utilizationRate = 50; // default utilization rate is 50
        maxUtilizationRate = 75; // default max utilization rate is 50
        _nextSigmaUpdate = block.timestamp + 3600;
        sigma = 70;
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
        require(sigma >=15 && sigma <=145, "invalid sigma");
        uint sigmaIndex = sigma / 5;
        return sigmaIndex;
    }

    /**
     * @notice check option cost for given amount of option
     */
    function premiumCost(uint amount, IOption optionContract) public override view returns(uint) {
        // notice the CDF is already multiplied by cdfDataContract.Amplifier()
        uint cdf = cdfDataContract.CDF(optionContract.getDuration(), _sigmaToIndex());
        // note the price is for 1exp(decimals)
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

        // should update sigma while sigma period expired
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
            uint64 s = sigma;
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
        _nextSigmaUpdate = block.timestamp + 3600;
    }
    
    /**
     * @notice adjust sigma manually
     */
    function adjustSigma(uint64 newSigma) external override onlyOwner {
        require (newSigma % 5 == 0, "needs 5*N");
        require (newSigma >= 15 && newSigma <= 145, "out of range [15,145]");
        
        sigma = newSigma;
        
        emit SigmaSet(sigma);
    }

    /**
     * @notice poolers claim premium USDTs;
     */
    function claimPremium() external override whenPoolerNotPaused {
        claimPremiumForRounds(uint(-1));
    }
    
    /**
     * @notice poolers claim premium USDTs for num rounds.
     */
    function claimPremiumForRounds(uint numRounds) public override whenPoolerNotPaused {
        // settle un-distributed premiums in rounds to _premiumBalance;
        _settlePremium(msg.sender, numRounds);
        
        // send USDTs premium back to senders's address
        uint amountUSDTPremium = _premiumBalance[msg.sender];
        _premiumBalance[msg.sender] = 0; // zero premium balance
        
        // extra check the amount is not 0;
        if (amountUSDTPremium > 0) {
            USDTContract.safeTransfer(msg.sender, amountUSDTPremium);
        }
    }
    
    /**
     * @notice settle premium in rounds while pooler token tranfsers.
     */
    function settlePremiumByPoolerToken(address account) external override onlyPoolerTokenContract {
        _settlePremium(account, uint(-1));
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
        if (poolerTokenContract.totalSupply() > 0) {
            uint premiumShare = option.totalPremiums()
                                .mul(PREMIUM_SHARE_MULTIPLIER)      // mul share with PREMIUM_SHARE_MULTIPLIER to prevent from underflow
                                .div(poolerTokenContract.totalSupply());
                                
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
     * @return false means the rounds has terminated due to gas limit
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
        for (uint i = 0; i < options.length; i++) {
            IOption option = options[i];
            
            // shift premium from settled rounds with rounds control
            uint maxRound = option.getRound();
            uint lastSettledRound = option.getSettledPremiumRound(account);
            
            for (uint r = lastSettledRound + 1; r < maxRound; r++) {
                uint roundPremium = option.getRoundPremiumShare(r)
                                            .mul(accountCollateral)
                                            .div(PREMIUM_SHARE_MULTIPLIER);  // remember to div by PREMIUM_SHARE_MULTIPLIER
                    
                // shift un-distributed premiums to _premiumBalance
                _premiumBalance[account] = _premiumBalance[account].add(roundPremium);
                
                // record last settled round
                lastSettledRound = r;

                // @dev BLOCK GAS LIMIT PROBLEM
                // poolers needs to submit multiple transactions to claim ALL premiums in all rounds
                // due to gas limit.
                roundsCounter++;
                if (roundsCounter >= numRounds) {
                    // mark max round premium claimed and return.
                    option.setSettledPremiumRound(lastSettledRound, account);
                    return false;
                }
            }
            
            // mark max round premium claimed and proceed.
            option.setSettledPremiumRound(lastSettledRound, account);
        }
        
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
        
        // add un-distributed premium with _premiumBalance
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
            
            // get current round 
            uint currentRound = option.getRound();
            
            // sum all profits from all un-claimed rounds
            uint [] memory rounds  = option.getUnclaimedProfitsRounds(msg.sender);
            
            for (uint j = 0; j<rounds.length; j++) {
                uint round = rounds[j];
                
                // remember to exclude the current round(which has not settled)
                if (round == currentRound) {
                    continue;
                }
                
                uint settlePrice = option.getRoundSettlePrice(round);
                uint strikePrice = option.getRoundStrikePrice(round);
                uint optionAmount = option.getRoundBalanceOf(round, msg.sender);
                
                // accumulate gain in rounds    
                accountProfits = accountProfits.add(_calcProfits(settlePrice, strikePrice, optionAmount));
            }
            
            // clear unclaimed rounds(claimed)
            option.clearUnclaimedProfitsRounds(msg.sender);
        }
        
        // extra check the amount is not 0;
        if (accountProfits > 0) {
            _sendProfits(msg.sender, accountProfits);
        }
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
        uint [] memory rounds  = option.getUnclaimedProfitsRounds(msg.sender);
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
    function setUtilizationRate(uint rate) external override onlyOwner {
        require(rate >=0 && rate <= 100, "rate[0,100]");
        utilizationRate = rate;
    }
    
    /**
     * @notice set max utilization rate by owner
     */
    function setMaxUtilizationRate(uint maxrate) external override onlyOwner {
        require(maxrate >=0 && maxrate <= 100, "rate[0,100]");
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
 * @title Implementation of Call Option Pool
 */
contract ETHCallOptionPool is OptionPoolBase {
    /**
     * @param USDTContract Tether USDT contract address
     * @param priceFeed Chainlink contract for getting Ether price
     */
    constructor(IERC20 USDTContract,  AggregatorV3Interface priceFeed, CDFDataInterface cdfContract, uint numOptions)
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
        require (amountETH <= poolerTokenContract.balanceOf(msg.sender), "insufficient balance");
        require (amountETH <= NWA(), "insufficient collateral");

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
        if (settlePrice > strikePrice) { 
            // calculate ratio
            uint ratio = settlePrice.sub(strikePrice)
                                    .mul(1e12)          // mul by 1e12 here to prevent from underflow
                                    .div(strikePrice);
            
            // calculate ETH gain of this amount
            uint holderETHProfit = ratio.mul(optionAmount)
                                    .div(1e12);         // remember to div by 1e12 previous mul-ed
            
            return holderETHProfit;
        }
        
        return 0;
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
 * @title Implementation of Put Option Pool
 */
contract ETHPutOptionPool is OptionPoolBase {
    /**
     * @param USDTContract Tether USDT contract address
     * @param priceFeed Chainlink contract for getting Ether price
     */
    constructor(IERC20 USDTContract, AggregatorV3Interface priceFeed, CDFDataInterface cdfContract, uint numOptions)
        OptionPoolBase(USDTContract, priceFeed, cdfContract, numOptions)
        public { }

    /**
     * @dev Returns the pool of the contract.
     */
    function name() public pure returns (string memory) {
        return "ETH PUT POOL";
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
        require (amountUSDT <= poolerTokenContract.balanceOf(msg.sender), "insufficient balance");
        require (amountUSDT <= NWA(), "insufficient collateral");

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
        
        // @dev remember to div with ETH price unit (1 ether)
        total /= (1 ether);        
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
        if (settlePrice < strikePrice) {  // put option get profits at this round
            // calculate ratio
            uint ratio = strikePrice.sub(settlePrice)
                                    .mul(1e12)      // mul 1e12 to prevent from underflow
                                    .div(strikePrice);

            // holder share
            uint holderShare = ratio.mul(optionAmount);

         
            // convert to USDT gain
            uint holderUSDTProfit = holderShare.mul(strikePrice)
                                    .div(1e12)      // remember to div 1e12 previous multipied
                                    .div(1 ether);  // remember to div ETH price unit (1 ether)

            return holderUSDTProfit;
        }
    }

    /**
     * @notice get current new option supply
     */
    function _slotSupply(uint etherPrice) internal view override returns(uint) {
        // reset the contract
        // Formula : (collateral / numOptions) * utilizationRate / 100 / (etherPrice/ price unit)
       return collateral.mul(utilizationRate)
                            .mul(1 ether)
                            .div(100)
                            .div(_numOptions)
                            .div(etherPrice);
    }
}
