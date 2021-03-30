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

contract Staking is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint;
    
    uint256 internal constant SHARE_MULTIPLIER = 1e18; // share multiplier to avert division underflow

    address internal _owner; // owner of this contract

    IERC20 public AssetContract;
    IERC20 public OPAContract;
    
    mapping (address => uint256) private _balances; 
    uint256 private _totalStaked;

    /**
     * OPA Rewarding
     */
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
    
    constructor(IERC20 opaContract, IERC20 assetContract, address owner) public {
        AssetContract = assetContract; 
        OPAContract = opaContract;
        _owner = owner;
    }

    /**
     * @dev stake some assets
     */
    function stake(uint256 amount) external {
        updateOPAReward();
        
        // transfer asset from AssetContract
        AssetContract.safeTransferFrom(msg.sender, address(this), amount);
        _balances[msg.sender] += amount;
        _totalStaked += amount;
    }
    
    /**
     * @dev claim rewards only
     */
    function claimRewards() external {
        updateOPAReward();
        
        _claimRewardsInternal(msg.sender);
    }
    
    /**
     * @dev withdraw the staked assets
     */
    function withdraw(uint256 amount) external {
        require(amount <= _balances[msg.sender], "balance exceeded");

        updateOPAReward();

        // modifiy
        _balances[msg.sender] -= amount;
        _totalStaked -= amount;
        
        // transfer assets back
        AssetContract.safeTransfer(msg.sender, amount);
    }

    /**
     * @dev return total staked value
     */
    function totalStaked() public view returns (uint256) {
        return _totalStaked;
    }
    
    /**
     * @notice sum unclaimed OPA;
     */
    function checkReward(address account) external view returns(uint256 opa) {
        uint accountCollateral = _balances[account];
        uint lastSettledOPARound = _settledOPARounds[account];
        
        // OPA reward = unsettledOPA + newMinedOPA
        uint unsettledOPA = _opaAccShares[_currentOPARound-1].sub(_opaAccShares[lastSettledOPARound]);
        uint newMinedOPAShare;
        
        if (_totalStaked > 0) {
            uint blocksToReward = block.number.sub(_lastRewardBlock);
            uint mintedOPA = OPABlockReward.mul(blocksToReward);
    
            // OPA share
            newMinedOPAShare = mintedOPA.mul(SHARE_MULTIPLIER)
                                        .div(_totalStaked);
        }
        
        return (unsettledOPA + newMinedOPAShare).mul(accountCollateral)
                                            .div(SHARE_MULTIPLIER);  // remember to div by SHARE_MULTIPLIER;
    }
    
    /**
     * @dev set OPA reward per height
     */
    function setOPAReward(uint256 amount) external onlyOwner {
        OPABlockReward = amount;
    }
     
     /**
     * @dev update accumulated OPA block reward until block
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
    
   /**
     * @dev claim rewards internal
     */
    function _claimRewardsInternal(address account) internal {
        // settle this account
        uint accountCollateral = _balances[account];
        uint lastSettledOPARound = _settledOPARounds[account];
        uint newSettledOPARound = _currentOPARound - 1;
        
        // round OPA
        uint roundOPA = _opaAccShares[newSettledOPARound].sub(_opaAccShares[lastSettledOPARound])
                                .mul(accountCollateral)
                                .div(SHARE_MULTIPLIER);  // remember to div by SHARE_MULTIPLIER    
                                
        // mark new settled OPA round
        _settledOPARounds[account] = newSettledOPARound;
        
        // transfer to account
        OPAContract.safeTransfer(account, roundOPA);
    }
}