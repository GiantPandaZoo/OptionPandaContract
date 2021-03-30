// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "library.sol";

contract Staking {
    using SafeERC20 for IERC20;
    using SafeMath for uint;
    
    uint256 internal constant SHARE_MULTIPLIER = 1e18; // share multiplier to avert division underflow

    address internal _owner; // owner of this contract

    IERC20 public AssetContract;
    IERC20 public OPAContract;
    
    mapping (address => uint256) private _balances; 
    uint256 private _totalSupply;

    /**
     * OPA Rewarding
     */
    /// @dev initial block reward for this pool
    uint256 public OPABlockReward = 0;

    /// @dev round index mapping to accumulate share.
    mapping (uint => uint) private _opaAccShares;
    /// @dev mark pooler's highest settled OPA round.
    mapping (address => uint) private _settledOPARounds;
    /// @dev a monotonic increasing OPA round index, STARTS FROM 1
    uint256 private _currentOPARound = 1;
    // @dev last OPA reward block
    uint256 private _lastRewardBlock = block.number;
    
    /**
     * @dev Modifier to make a function callable only by owner
     */
    modifier onlyOwner() {
        require(msg.sender == _owner, "restricted");
        _;
    }
    
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
        _totalSupply += amount;
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
        updateOPAReward();

        require(amount >= _balances[msg.sender], "balance exceeded");
        _balances[msg.sender] -= amount;
        _totalSupply -= amount;
    }

    /**
     * @notice poolers sum unclaimed OPA;
     */
    function checkReward(address account) external view returns(uint256 opa) {
        uint accountCollateral = _balances[account];
        uint lastSettledOPARound = _settledOPARounds[account];
        
        // OPA reward = unsettledOPA + newMinedOPA
        uint unsettledOPA = _opaAccShares[_currentOPARound-1].sub(_opaAccShares[lastSettledOPARound]);
        uint newMinedOPAShare;
        
        if (_totalSupply > 0) {
            uint blocksToReward = block.number.sub(_lastRewardBlock);
            uint mintedOPA = OPABlockReward.mul(blocksToReward);
    
            // OPA share
            newMinedOPAShare = mintedOPA.mul(SHARE_MULTIPLIER)
                                        .div(_totalSupply);
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
    
        // settle OPA share for this round
        uint roundOPAShare;
        if (_totalSupply > 0) {
            uint blocksToReward = block.number.sub(_lastRewardBlock);
            uint mintedOPA = OPABlockReward.mul(blocksToReward);
    
            // OPA share
            roundOPAShare = mintedOPA.mul(SHARE_MULTIPLIER)
                                        .div(_totalSupply);
                                    
            // mark block rewarded;
            _lastRewardBlock = block.number;
        }
                
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