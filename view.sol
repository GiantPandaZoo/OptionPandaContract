// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "library.sol";

contract PandaView {
    using SafeMath for uint256;
    
    uint constant monthSecs = 30 * 24 * 60 * 60;
    
    struct RoundData {
        uint256 balance;
        uint expiryDate;
        uint strikePrice;
        uint settlePrice;
    }
    
    /**
     * get a buyer's round in recent month
     */
    function getBuyerRounds(IOption option, address account) external view returns(RoundData[] memory) {
        uint duration = option.getDuration();
        uint maxRounds = monthSecs / duration;
        
        RoundData[] memory rounds = new RoundData[](maxRounds);
        
        uint roundCount;
        uint monthAgo = block.timestamp.sub(monthSecs);
        
        for (uint r = option.getRound(); r > 0 ;r--) {
            uint expiryDate = option.getRoundExpiryDate(r);
            if (expiryDate < monthAgo){
                break;
            }
            
            uint256 balance = option.getRoundBalanceOf(r, account);
            if (balance > 0) { // found position
                rounds[roundCount].balance = balance;
                rounds[roundCount].expiryDate = expiryDate;
                rounds[roundCount].strikePrice = option.getRoundStrikePrice(r);
                rounds[roundCount].settlePrice = option.getRoundSettlePrice(r);
                roundCount++;
            }
        }
        
        // copy to a smaller memory array, slicing
        if (roundCount < maxRounds) {
            RoundData[] memory rs = new RoundData[](roundCount);
            for (uint i = 0;i<rs.length; i++) {
                rs[i] = rounds[i];
            }
            // return the array
            return rs;
        }
        
        return rounds;
    }
}