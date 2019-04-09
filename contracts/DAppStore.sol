pragma solidity ^0.5.2;

import "./token/MiniMeTokenInterface.sol";
import "./token/ApproveAndCallFallBack.sol";
import "./utils/SafeMath.sol";
import "./utils/BancorFormula.sol";


contract DAppStore is ApproveAndCallFallBack, BancorFormula {
    using SafeMath for uint;

    // Could be any EIP20/MiniMe token
    MiniMeTokenInterface SNT;

    // Total SNT in circulation
    uint public total;
    
    // Parameter to calculate Max SNT any one DApp can stake
    uint public ceiling;

    // The max amount of tokens it is possible to stake, as a percentage of the total in circulation
    uint public max;

    // Decimal precision for this contract
    uint public decimals;

    // Prevents overflows in votesMinted
    uint public safeMax;
    
    // Whether we need more than an id param to identify arbitrary data must still be discussed.
    struct Data {
        address developer;
        bytes32 id;
        uint balance;
        uint rate;
        uint available;
        uint votesMinted;
        uint votesCast;
        uint effectiveBalance;
    }
    
    Data[] public dapps;
    mapping(bytes32 => uint) public id2index;
    
    event DAppCreated(bytes32 indexed id, uint votesMint, uint amount);
    event Upvote(bytes32 indexed id, uint newEffectiveBalance);
    event Downvote(bytes32 indexed id, uint newEffectiveBalance);
    event Withdraw(bytes32 indexed id, uint newEffectiveBalance);
    
    constructor(MiniMeTokenInterface _SNT) public {
        SNT = _SNT;
        
        total = 3470483788;

        ceiling = 588;   // See here for more: https://observablehq.com/@andytudhope/dapp-store-snt-curation-mechanism

        decimals = 1000000; // 4 decimal points for %, 2 because we only use 1/100th of total in circulation
        
        max = (total * ceiling) / decimals; 

        safeMax = 98 * max / 100;
    }
    
    /**
     * @dev Anyone can create a DApp (i.e an arb piece of data this contract happens to care about).
     * @param _id bytes32 unique identifier.
     * @param _amount of tokens to stake on initial ranking.
     */
    function createDApp(bytes32 _id, uint _amount) external { 
        _createDApp(msg.sender, _id, _amount);
    }
    
    function _createDApp(address _from, bytes32 _id, uint _amount) internal {
        require(_amount > 0, "You must spend some SNT to submit a ranking in order to avoid spam");
        require (_amount < safeMax, "You cannot stake more SNT than the ceiling dictates");
        
        uint dappIdx = dapps.length;
        
        dapps.length++;

        Data storage d = dapps[dappIdx];
        d.developer = _from;
        d.id = _id;
        
        uint precision;
        uint result;
        
        d.balance = _amount;
        d.rate = decimals - (d.balance * decimals/max);
        d.available = d.balance * d.rate;
        
        (result, precision) = BancorFormula.power(
            d.available, 
            decimals, 
            uint32(decimals), 
            uint32(d.rate));
        
        d.votesMinted = result >> precision;
        d.votesCast = 0;
        d.effectiveBalance = _amount;

        id2index[_id] = dappIdx;

        require(SNT.allowance(_from, address(this)) >= _amount, "Not enough SNT allowance");
        require(SNT.transferFrom(_from, address(this), _amount), "Transfer failed");

        emit DAppCreated(_id, d.votesMinted, d.effectiveBalance);
    }
    
    /**
     * @dev Used in UI to display effect on ranking of user's donation
     * @param _id bytes32 unique identifier.
     * @param _amount of tokens to stake/"donate" to this DApp's ranking.
     * @return effect of donation on DApp's effectiveBalance 
     */
    function upvoteEffect(bytes32 _id, uint _amount) external view returns(uint effect) { 
        uint dappIdx = id2index[_id];
        Data memory d = dapps[dappIdx];
        require(d.id == _id, "Error fetching correct data");
        require(d.balance + _amount < safeMax, "You cannot upvote by this much, try with a lower amount");

        // Special case - no downvotes yet cast
        if (d.votesCast == 0) {
            return _amount;
        }

        uint precision;
        uint result;
        
        uint mBalance = d.balance + _amount;
        uint mRate = decimals - (mBalance * decimals/max);
        uint mAvailable = mBalance * mRate;
        
        (result, precision) = BancorFormula.power(
            mAvailable, 
            decimals, 
            uint32(decimals), 
            uint32(mRate));
        
        uint mVMinted = result >> precision;

        uint temp1 = d.votesCast * mRate * mAvailable;
        uint temp2 = mVMinted * decimals * decimals;
        uint mEffect = temp1 / temp2;
        
        uint mEBalance = mBalance - mEffect;
        
        return (mEBalance - d.effectiveBalance);
    }
    
    /**
     * @dev Sends SNT directly to the contract, not the developer. This gets added to the DApp's balance, no curve required.
     * @param _id bytes32 unique identifier.
     * @param _amount of tokens to stake on DApp's ranking. Used for upvoting + staking more.
     */
    function upvote(bytes32 _id, uint _amount) external { 
        _upvote(msg.sender, _id, _amount);
    }
    
    function _upvote(address _from, bytes32 _id, uint _amount) internal { 
        require(_amount > 0, "You must send some SNT in order to upvote");
        
        uint dappIdx = id2index[_id];
        Data storage d = dapps[dappIdx];
        require(d.id == _id, "Error fetching correct data");
        
        require(d.balance + _amount < safeMax, "You cannot upvote by this much, try with a lower amount");
        
        uint precision;
        uint result;

        d.balance = d.balance + _amount;
        d.rate = decimals - (d.balance * decimals/max);
        d.available = d.balance * d.rate;
        
        (result, precision) = BancorFormula.power(
            d.available, 
            decimals, 
            uint32(decimals), 
            uint32(d.rate));
        
        d.votesMinted = result >> precision;

        uint temp1 = d.votesCast * d.rate * d.available;
        uint temp2 = d.votesMinted * decimals * decimals;
        uint effect = temp1 / temp2;

        d.effectiveBalance = d.balance - effect;

        require(SNT.allowance(_from, address(this)) >= _amount, "Not enough SNT allowance");
        require(SNT.transferFrom(_from, address(this), _amount), "Transfer failed");
        
        emit Upvote(_id, d.effectiveBalance);
    }

    /**
     * @dev Downvotes always remove 1% of the current ranking.
     * @param _id bytes32 unique identifier. 
     * @return balance_down_by, votes_required, cost
     */
    function downvoteCost(bytes32 _id) public view returns(uint b, uint v_r, uint c) { 
        uint dappIdx = id2index[_id];
        Data memory d = dapps[dappIdx];
        require(d.id == _id, "Error fetching correct data");
        
        uint balanceDownBy = (d.effectiveBalance / 100);
        uint votesRequired = (balanceDownBy * d.votesMinted * d.rate) / d.available;
        uint votesAvailable = d.votesMinted - d.votesCast - votesRequired;
        uint temp = (d.available / votesAvailable) * (votesRequired);
        uint cost = temp / decimals;
        return (balanceDownBy, votesRequired, cost);
    }
    
    /**
     * @dev Sends SNT to the developer and lowers the DApp's effective balance by 1%
     * @param _id bytes32 unique identifier.
     * @param _amount uint, included for approveAndCallFallBack
     */
    function downvote(bytes32 _id, uint _amount) external {
        (,,uint c) = downvoteCost(_id);
        require(_amount == c, "Incorrect amount: valid iff effect on ranking is 1%");
        _downvote(msg.sender, _id, c);
    }
    
    function _downvote(address _from, bytes32 _id, uint _amount) internal { 
        uint dappIdx = id2index[_id];
        Data storage d = dapps[dappIdx];
        require(d.id == _id, "Error fetching correct data");
        
        (uint b, uint v_r, uint c) = downvoteCost(_id);

        require(_amount == c, "Incorrect amount: valid iff effect on ranking is 1%");
        
        d.available = d.available - _amount;
        d.votesCast = d.votesCast + v_r;
        d.effectiveBalance = d.effectiveBalance - b;

        require(SNT.allowance(_from, address(this)) >= _amount, "Not enough SNT allowance");
        require(SNT.transferFrom(_from, address(this), _amount), "Transfer failed");
        require(SNT.transfer(d.developer, _amount), "Transfer failed");
        
        emit Downvote(_id, d.effectiveBalance);
    }
    
    /**
     * @dev Developers can withdraw an amount not more than what was available of the
        SNT they originally staked minus what they have already received back in downvotes.
     * @param _id bytes32 unique identifier.
     * @param _amount of tokens to withdraw from DApp's overall balance.
     */
    function withdraw(bytes32 _id, uint _amount) external { 
        uint dappIdx = id2index[_id];
        Data storage d = dapps[dappIdx];
        require(d.id == _id, "Error fetching correct data");
        
        require(msg.sender == d.developer, "Only the developer can withdraw SNT staked on this data");
        require(_amount <= d.available, "You can only withdraw a percentage of the SNT staked, less what you have already received");
        
        uint precision;
        uint result;

        d.balance = d.balance - _amount;
        d.rate = decimals - (d.balance * decimals/max);
        d.available = d.balance * d.rate;
        
        (result, precision) = BancorFormula.power(
            d.available, 
            decimals, 
            uint32(decimals), 
            uint32(d.rate));
        
        d.votesMinted = result >> precision;
        if (d.votesCast > d.votesMinted) {
            d.votesCast = d.votesMinted;
        }
        
        uint temp1 = d.votesCast * d.rate * d.available;
        uint temp2 = d.votesMinted * decimals * decimals;
        uint effect = temp1 / temp2;

        d.effectiveBalance = d.balance - effect;
        
        require(SNT.transfer(d.developer, _amount), "Transfer failed");
        
        emit Withdraw(_id, d.effectiveBalance);
    }
    
    /**
     * @notice Support for "approveAndCall".  
     * @param _from Who approved.
     * @param _amount Amount being approved, needs to be equal `_amount` or `cost`.
     * @param _token Token being approved, needs to be `SNT`.
     * @param _data Abi encoded data with selector of `register(bytes32,address,bytes32,bytes32)`.
     */
    function receiveApproval(
        address _from,
        uint256 _amount,
        address _token,
        bytes calldata _data
    ) 
        external
    {
        require(_token == address(SNT), "Wrong token");
        require(_token == address(msg.sender), "Wrong account");
        require(_data.length <= 132, "Incorrect data");
        
        bytes4 sig;
        bytes32 id;
        uint256 amount;

        (sig, id, amount) = abiDecodeRegister(_data);
        
        require(_amount == amount, "Wrong amount");

        if (sig == bytes4(0x1a214f43)) {
            _createDApp(_from, id, amount);
        } else if (sig == bytes4(0xac769090)) {
            _downvote(_from, id, amount);
        } else if (sig == bytes4(0x2b3df690)) {
            _upvote(_from, id, amount);
        } else {
            revert("Wrong method selector");
        }
    }
      
    /**
     * @dev Decodes abi encoded data with selector for "functionName(bytes32,uint256)".
     * @param _data Abi encoded data.
     * @return Decoded registry call.
     */
    function abiDecodeRegister(
        bytes memory _data
    ) 
        private  
        returns(
            bytes4 sig,
            bytes32 id,
            uint256 amount
        )
    {
        assembly {
            sig := mload(add(_data, add(0x20, 0)))
            id := mload(add(_data, 36))
            amount := mload(add(_data, 68))
        }
    }

}
