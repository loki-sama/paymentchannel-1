pragma solidity ^0.4.18;

import './ECVerification.sol';
import './lib/safeMath.sol';
import './token/Token.sol';

contract Channel is ECVerification {

    using SafeMath for uint256;

    address factory;
    address public sender;
    address public receiver;
    uint public challengePeriod;
    uint public startDate;
    uint challengeStartTime;

    uint depositedBalance = 0;
    uint withdrawnBalance = 0;
    uint balanceInChallenge = 0;

    enum State {Initiated, Recharged, InChallenge, Settled }
    State status;

    Token public token;

    modifier onlyFactory() {
        require(msg.sender == factory);
        _;
    }

    modifier originReceiver() {
        require(tx.origin == receiver);
        _;
    }

    modifier originSender() {
        require(tx.origin == sender);
        _;
    }

    modifier originSenderOrReceiver() {
        require(tx.origin == sender || tx.origin == receiver);
        _;
    }

    function Channel(address _receiver, address _sender, address _tokenAddress, uint _challengePeriod) 
    public
    {       
        token = Token(_tokenAddress);
        require(token.totalSupply() > 0);
        receiver = _receiver;
        sender = _sender;        
        challengePeriod = _challengePeriod;
        startDate = now;
        status = State.Initiated;
    }

    function recharge(uint _deposit) 
    external 
    onlyFactory originSender 
    returns (bool)
    {
        require(token.allowance(sender, address(this)) >= _deposit);
        require(token.transferFrom(sender, address(this), _deposit));
        depositedBalance = _deposit;
        status = State.Recharged;

        return true;
    }

    function withdraw(uint _balance, bytes _signedBalanceMsg)
    external
    originReceiver onlyFactory
    returns (bool)
    {
        require(status == State.Recharged);
        require(_balance >= depositedBalance.sub(withdrawnBalance));
                
        // Derive sender address from signed balance proof
        address senderAddress = extractBalanceProofSignature(
            receiver,
            _balance,
            _signedBalanceMsg
        );
        require(senderAddress == sender);
        // Update total withdrawn balance
        withdrawnBalance = withdrawnBalance.add(_balance);

        // Send the remaining balance to the receiver
        require(token.transfer(receiver, _balance));

        return true;
    }
    
    function mutualSettlement(uint _balance, bytes _signedBalanceMsg, bytes _signedClosingMsg)
    external
    originSenderOrReceiver onlyFactory
    returns (bool)
    {
        require(_balance <= depositedBalance);
        
        // Derive sender address from signed balance proof
        address senderAddr = extractBalanceProofSignature(
            receiver,
            _balance,
            _signedBalanceMsg
        );

        // Derive receiver address from closing signature
        address receiverAddr = extractClosingSignature(
            senderAddr,
            _balance,
            _signedClosingMsg
        );
        require(receiverAddr == receiver);

        // Both signatures have been verified and the channel can be settled.
        require(settleChannel(sender, receiver, _balance));
        return true;
    }

    function challengedSettlement(uint _balance)
    external
    originSender onlyFactory
    returns (bool)
    {
        require(status == State.Recharged);
        require(_balance <= depositedBalance);

        challengeStartTime = now;
        status = State.InChallenge;
        balanceInChallenge = _balance;
        return true;
    }
    
    function afterChallengeSettle() 
    external 
    originSender onlyFactory
    returns (uint)
    {
        require(status == State.InChallenge); 
        require(now > challengeStartTime + challengePeriod * 1 seconds);  

        require(settleChannel(sender, receiver, balanceInChallenge));
        return balanceInChallenge;
    }    


    function getChannelInfo() onlyFactory external view returns (address, address, uint, uint, State, uint, uint){
        return( sender,
                receiver,
                challengePeriod,
                startDate,
                status,
                depositedBalance,
                withdrawnBalance
                );
    }
    
    function extractBalanceProofSignature(address _receiverAddress, uint256 _balance, bytes _signedBalanceMsg)
    internal view
    returns (address)
    {
        bytes32 msgHash = keccak256(
            keccak256(
                "string msgId",
                "address receiver",
                "uint balance",
                "address contract"
            ),
            keccak256(
                "Sender Balance Proof Sign",
                _receiverAddress,
                _balance,   
                address(this)
            )
        );

        // Derive address from signature
        address signer = ECVerification.ecverify(msgHash, _signedBalanceMsg);
        return signer;
    }

    function extractClosingSignature(address _senderAddress, uint _balance, bytes _signedClosingMsg)
    internal view
    returns (address)
    {
        bytes32 msgHash = keccak256(
            keccak256(
                "string msgId",
                "address sender",
                "uint balance",
                "address contract"
            ),
            keccak256(
                "Receiver Closing Sign",
                _senderAddress,
                _balance,
                address(this)
            )
        );

        // Derive address from signature
        address signer = ECVerification.ecverify(msgHash, _signedClosingMsg);
        return signer;
    } 

    function settleChannel(address _senderAddress, address _receiverAddress, uint _balance)
    internal 
    returns (bool)
    {
        // Send the unwithdrawn _balance to the receiver
        uint receiverRemainingTokens = _balance.sub(withdrawnBalance);
        status = State.Settled;
        require(token.transfer(_receiverAddress, receiverRemainingTokens));

        // Send remaining tokens back to sender
        require(token.transfer(_senderAddress, depositedBalance.sub(receiverRemainingTokens)));
        return true;
    }

}