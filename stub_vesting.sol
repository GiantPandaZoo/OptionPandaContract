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
 * @title a simple bridge non-vesting for early usage
 */
contract StubVesting is IVesting, Ownable {
    using SafeERC20 for IERC20;
    IERC20 public immutable OPAToken;  // OPA token contract

    /**
     * @dev Emitted when an account is set vestable
     */
    event Vestable(address account);
    /**
     * @dev Emitted when an account is set unvestable
     */
    event Unvestable(address account);

    // @dev vestable group
    mapping(address => bool) public vestableGroup;
    
    modifier onlyVestableGroup() {
        require(vestableGroup[msg.sender], "not in vestable group");
        _;
    }
    
    constructor(IERC20 opaToken) public{
        OPAToken = opaToken;
    }
    
    /**
     * @dev set or remove address to vestable group
     */
    function setVestable(address account, bool allow) external onlyOwner {
        vestableGroup[account] = allow;
        if (allow) {
            emit Vestable(account);
        }  else {
            emit Unvestable(account);
        }
    }
    
    /**
     * @dev stub vesting function, just refund to account
     */
    function vest(address account, uint amount) external override onlyVestableGroup {
        OPAToken.safeTransfer(account, amount);
    }
}