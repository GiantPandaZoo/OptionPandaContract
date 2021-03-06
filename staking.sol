// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "library.sol";

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor () internal {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

/**
 * @dev Option Panda Staking Contract for LP token & OPA token
 */
contract Staking is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint;
    
    uint256 internal constant SHARE_MULTIPLIER = 1e18; // share multiplier to avert division underflow
    
    IERC20 public AssetContract; // the asset to stake
    IERC20 public OPAContract; // the OPA token contract
    address public rewardAccount = 0xA13682C85d574ce5E2571cd685277D8C9726620E; // Liquidity Mining Reward account

    mapping (address => uint256) private _balances; // tracking staker's value
    mapping (address => uint256) internal _opaBalance; // tracking staker's claimable OPA tokens
    uint256 private _totalStaked; // track total staked value

    /// @dev initial block reward
    uint256 public OPABlockReward = 0;

    /// @dev round index mapping to accumulate share.
    mapping (uint => uint) private _opaAccShares;
    /// @dev mark staker's highest settled OPA round.
    mapping (address => uint) private _settledOPARounds;
    /// @dev a monotonic increasing OPA round index, STARTS FROM 1
    uint256 private _currentOPARound = 1;
    // @dev last OPA reward block
    uint256 private _lastRewardBlock = block.number;
    
    constructor(IERC20 opaContract, IERC20 assetContract) public {
        AssetContract = assetContract; 
        OPAContract = opaContract;
    }
    
    /**
     * @notice set OPA transfer account
     */
    function setOPARewardAccount(address rewardAccount_) external onlyOwner {
        rewardAccount = rewardAccount_;
    }

    /**
     * @dev stake some assets
     */
    function stake(uint256 amount) external {
        // settle previous rewards
        settleStaker(msg.sender);
        
        // transfer asset from AssetContract
        AssetContract.safeTransferFrom(msg.sender, address(this), amount);
        _balances[msg.sender] += amount;
        _totalStaked += amount;
    }
    
    /**
     * @dev claim rewards only
     */
    function claimRewards() external {
        // settle previous rewards
        settleStaker(msg.sender);
        
        // OPA balance modification
        uint amountOPA = _opaBalance[msg.sender];
        delete _opaBalance[msg.sender]; // zero OPA balance

        // transfer OPA to sender
        OPAContract.safeTransferFrom(rewardAccount, msg.sender, amountOPA);
    }
    
    /**
     * @dev withdraw the staked assets
     */
    function withdraw(uint256 amount) external {
        require(amount <= _balances[msg.sender], "balance exceeded");

        // settle previous rewards
        settleStaker(msg.sender);

        // modifiy
        _balances[msg.sender] -= amount;
        _totalStaked -= amount;
        
        // transfer assets back
        AssetContract.safeTransfer(msg.sender, amount);
    }
    
    /**
     * @dev return value staked for an account
     */
    function numStaked(address account) external view returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev return total staked value
     */
    function totalStaked() external view returns (uint256) {
        return _totalStaked;
    }
    
    /**
     * @notice sum unclaimed OPA;
     */
    function checkReward(address account) external view returns(uint256 opa) {
        uint accountCollateral = _balances[account];
        uint lastSettledOPARound = _settledOPARounds[account];
        
        // OPA reward = settledOPA + unsettledOPA + newMinedOPA
        uint unsettledOPAShare = _opaAccShares[_currentOPARound-1].sub(_opaAccShares[lastSettledOPARound]);
        
        uint newMinedOPAShare;
        if (_totalStaked > 0) {
            uint blocksToReward = block.number.sub(_lastRewardBlock);
            uint mintedOPA = OPABlockReward.mul(blocksToReward);
    
            // OPA share
            newMinedOPAShare = mintedOPA.mul(SHARE_MULTIPLIER)
                                        .div(_totalStaked);
        }
        
        return _opaBalance[account] + (unsettledOPAShare + newMinedOPAShare).mul(accountCollateral)
                                            .div(SHARE_MULTIPLIER);  // remember to div by SHARE_MULTIPLIER;
    }
    
    /**
     * @dev set OPA reward per height
     */
    function setOPAReward(uint256 reward) external onlyOwner {
        // settle previous rewards
        updateOPAReward();
        // set new block reward
        OPABlockReward = reward;
    }
    
    /**
     * @dev settle a staker
     */
    function settleStaker(address account) internal {
        // update OPA reward snapshot
        updateOPAReward();
        
        // settle this account
        uint accountCollateral = _balances[account];
        uint lastSettledOPARound = _settledOPARounds[account];
        uint newSettledOPARound = _currentOPARound - 1;
        
        // round OPA
        uint roundOPA = _opaAccShares[newSettledOPARound].sub(_opaAccShares[lastSettledOPARound])
                                .mul(accountCollateral)
                                .div(SHARE_MULTIPLIER);  // remember to div by SHARE_MULTIPLIER    
        
        // update OPA balance
        _opaBalance[account] += roundOPA;
        
        // mark new settled OPA round
        _settledOPARounds[account] = newSettledOPARound;
    }
     
     /**
     * @dev update accumulated OPA block reward until current block
     */
    function updateOPAReward() internal {
        // skip round changing in the same block
        if (_lastRewardBlock == block.number) {
            return;
        }
    
        // postpone OPA rewarding if there is none staker
        if (_totalStaked == 0) {
            return;
        }

        // settle OPA share for [_lastRewardBlock, block.number]
        uint blocksToReward = block.number.sub(_lastRewardBlock);
        uint mintedOPA = OPABlockReward.mul(blocksToReward);

        // OPA share
        uint roundOPAShare = mintedOPA.mul(SHARE_MULTIPLIER)
                                    .div(_totalStaked);
                                
        // mark block rewarded;
        _lastRewardBlock = block.number;
            
        // accumulate OPA share
        _opaAccShares[_currentOPARound] = roundOPAShare.add(_opaAccShares[_currentOPARound-1]); 
       
        // next round setting                                 
        _currentOPARound++;
    }
}