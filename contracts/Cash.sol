// (c) Kallol Borah, 2020
// Implementation of the Via cash token.

pragma solidity >=0.5.0 <0.7.0;

import "./erc/ERC20.sol";
import "./oraclize/ViaRate.sol";
import "./oraclize/EthToUSD.sol";
import "./utilities/StringUtils.sol";
import "./Factory.sol";
import "abdk-libraries-solidity/ABDKMathQuad.sol";
import "@openzeppelin/upgrades/contracts/Initializable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/ownership/Ownable.sol";

contract Cash is ERC20, Initializable, Ownable {

    using stringutils for *;

    //via token factory address
    Factory private factory;

    //name of Via token (eg, Via-USD)
    bytes32 public name;
    bytes32 public symbol;

    struct cash{
        bytes32 name;
        bytes16 balance;
    }

    //cash balances held by this issuer against which via cash tokens are issued
    mapping(address => cash[]) private cashbalances;

    struct depositor{
        address name;
        bytes32 currency;
    }

    //list of depositors via is issued to
    mapping(address => depositor[]) private depositors;

    //for Oraclize
    bytes32 EthXid;
    bytes32 ViaXid;
    
    struct conversion{
        bytes32 operation;
        address party;
        bytes16 amount;
        bytes32 currency;
        bytes32 EthXid;
        bytes16 EthXvalue;
        bytes32 name;
        bytes16 ViaXvalue;
    }

    mapping(bytes32 => conversion) private conversionQ;

    bytes32[] private conversions;

    //events to capture and report to Via oracle
    event ViaCashIssued(bytes32 currency, bytes16 value);
    event ViaCashRedeemed(bytes32 currency, bytes16 value);

    //initiliaze proxies
    function initialize(bytes32 _name, address _owner) public {
        Ownable.initialize(_owner);
        factory = Factory(_owner);
        name = _name;
        symbol = _name;
    }

    //handling pay in of ether for issue of via cash tokens
    function() external payable{
        //ether paid in
        require(msg.value !=0);
        //issue via cash tokens
        issue(ABDKMathQuad.fromUInt(msg.value), msg.sender, "ether");
    }

    //overriding this function of ERC20 standard
    function transferFrom(address sender, address receiver, uint256 tokens) public returns (bool){
        //owner should have more tokens than being transferred
        require(ABDKMathQuad.cmp(ABDKMathQuad.fromUInt(tokens), balances[sender])==-1 || ABDKMathQuad.cmp(ABDKMathQuad.fromUInt(tokens), balances[sender])==0);
        //sending contract should be allowed by token owner to make this transfer
        require(ABDKMathQuad.cmp(ABDKMathQuad.fromUInt(tokens), allowed[sender][msg.sender])==-1 || ABDKMathQuad.cmp(ABDKMathQuad.fromUInt(tokens), allowed[sender][msg.sender])==0);
        //check if tokens are being transferred to this cash contract
        if(receiver == address(this)){ 
            //if token name is the same, this transfer has to be redeemed
            if(Cash(address(msg.sender)).name()==name){ 
                if(redeem(ABDKMathQuad.fromUInt(tokens), receiver))
                    return true;
                else
                    return false;
            }
            //else request issue of cash tokens generated by this contract
            else{
                //only issue if cash tokens are paid in, since bond tokens can't be paid to issue bond token
                for(uint256 p=0; p<factory.getTokenCount(); p++){
                    address viaAddress = factory.tokens(p);
                    if(factory.getName(viaAddress) == Cash(address(msg.sender)).name() &&
                        factory.getType(viaAddress) != "ViaBond"){
                        issue(ABDKMathQuad.fromUInt(tokens), receiver, Cash(address(msg.sender)).name());
                        return true;
                    }
                }
                return false;
            }
        }
        else {
            //tokens are being sent to a user account
            balances[sender] = ABDKMathQuad.sub(balances[sender], ABDKMathQuad.fromUInt(tokens));
            allowed[sender][msg.sender] = ABDKMathQuad.sub(allowed[sender][msg.sender], ABDKMathQuad.fromUInt(tokens));
            balances[receiver] = ABDKMathQuad.add(balances[receiver], ABDKMathQuad.fromUInt(tokens));
            emit Transfer(sender, receiver, tokens);
            return true;
        }
    }
    
    //requesting issue of Via to buyer for amount of ether or some other via cash token
    function issue(bytes16 amount, address buyer, bytes32 currency) private {
        //ensure that brought amount is not zero
        require(amount != 0);
        bool found = false;
        uint256 p=0;
        //adds paid in currency to this contract's cash balance
        for(p=0; p<cashbalances[address(this)].length; p++){
            if(cashbalances[address(this)][p].name == currency){
                cashbalances[address(this)][p].balance = ABDKMathQuad.add(cashbalances[address(this)][p].balance, amount);
                found = true;
            }
        }
        if(!found){
            cashbalances[address(this)][p].name = currency;
            cashbalances[address(this)][p].balance = amount;
        }
        found = false;
        //add depositor to list of depositors
        for(p=0; p<depositors[address(this)].length; p++){
            if(depositors[address(this)][p].name == buyer &&
                depositors[address(this)][p].currency == currency){
                found = true;
            }
        }
        if(!found){
            depositors[address(this)][p].name = buyer;
            depositors[address(this)][p].currency = currency;
        }
        //find amount of via cash tokens to transfer after applying exchange rate
        if(currency=="ether"){
            EthXid = "9101112"; //only for testing
            new EthToUSD().update("Cash", address(this));
            if(name!="Via-USD"){
                ViaXid = "3456"; //only for testing
                conversionQ[ViaXid] = conversion("issue", buyer, amount, currency, EthXid, ABDKMathQuad.fromUInt(0), name, ABDKMathQuad.fromUInt(0));
                conversions.push(ViaXid);
                new ViaRate().requestPost(abi.encodePacked("Via_USD_to_", name),"ver","Cash", address(this));
            }
        }
        else{
            ViaXid = "1234"; //only for testing
            conversionQ[ViaXid] = conversion("issue", buyer, amount, currency, EthXid, ABDKMathQuad.fromUInt(0), name, ABDKMathQuad.fromUInt(0));
            conversions.push(ViaXid);
            new ViaRate().requestPost(abi.encodePacked(currency, "_to_", name),"er","Cash", address(this));
        }
        //conversionQ[ViaXid] = conversion("issue", buyer, amount, currency, EthXid, ABDKMathQuad.fromUInt(0), name, ABDKMathQuad.fromUInt(0));
        //conversions.push(ViaXid);
    }

    //requesting redemption of Via cash token and transfer of currency it was issued against
    function redeem(bytes16 amount, address seller) private returns(bool){
        //ensure that sold amount is not zero
        require(amount != 0);
        //find currency that seller had deposited earlier
        bool found = false;
        bytes32 currency;
        for(uint256 p=0; p<depositors[address(this)].length; p++){
            if(depositors[address(this)][p].name == seller){
                currency = depositors[address(this)][p].currency;
                found = true;
            }
        }
        if(found){
            //call Via oracle
            if(currency=="ether"){
                EthXid = "9101112"; //only for testing
                new EthToUSD().update("Cash", address(this));
                ViaXid = "3456"; //only for testing
                conversionQ[ViaXid] = conversion("redeem", seller, amount, currency, EthXid, ABDKMathQuad.fromUInt(0), name, ABDKMathQuad.fromUInt(0));
                conversions.push(ViaXid);
                new ViaRate().requestPost(abi.encodePacked(name, "_to_Via_USD"),"ver","Cash", address(this));
            }
            else{
                ViaXid = "1234"; //only for testing
                conversionQ[ViaXid] = conversion("redeem", seller, amount, currency, EthXid, ABDKMathQuad.fromUInt(0), name, ABDKMathQuad.fromUInt(0));
                conversions.push(ViaXid);
                new ViaRate().requestPost(abi.encodePacked(name, "_to_", currency),"er","Cash", address(this));
            }
            //conversionQ[ViaXid] = conversion("redeem", seller, amount, currency, EthXid, ABDKMathQuad.fromUInt(0), name, ABDKMathQuad.fromUInt(0));
            //conversions.push(ViaXid);
        }
        return found;
    }

    //function called back from Oraclize
    function convert(bytes32 txId, bytes16 result, bytes32 rtype) public {
        //check type of result returned
        if(rtype =="ethusd"){
            conversionQ[txId].EthXvalue = result;
        }
        if(rtype == "er"){
            conversionQ[txId].EthXvalue = result;
        }
        if(rtype == "ver"){
            conversionQ[txId].ViaXvalue = result;
        }
        //check if cash needs to be issued or redeemed
        if(conversionQ[txId].operation=="issue"){
            if(ABDKMathQuad.cmp(conversionQ[txId].EthXvalue, ABDKMathQuad.fromUInt(0))!=0 && ABDKMathQuad.cmp(conversionQ[txId].ViaXvalue, ABDKMathQuad.fromUInt(0))!=0){
                bytes16 via = convertToVia(conversionQ[txId].amount, conversionQ[txId].currency,conversionQ[txId].EthXvalue,result);
                finallyIssue(via, conversionQ[txId].party);
            }
        }
        else if(conversionQ[txId].operation=="redeem"){
            if(ABDKMathQuad.cmp(conversionQ[txId].EthXvalue, ABDKMathQuad.fromUInt(0))!=0 && ABDKMathQuad.cmp(conversionQ[txId].ViaXvalue, ABDKMathQuad.fromUInt(0))!=0){
                bytes16 value = convertFromVia(conversionQ[txId].amount, conversionQ[txId].currency,conversionQ[txId].EthXvalue,result);
                finallyRedeem(value, conversionQ[txId].currency, conversionQ[txId].party, conversionQ[txId].amount);
            }
        }
    }

    function finallyIssue(bytes16 via, address party) private {
        //add via to this contract's balance first (aka issue them first)
        ABDKMathQuad.add(balances[address(this)], via);
        //transfer amount to buyer 
        transfer(party, ABDKMathQuad.toUInt(via));
        //adjust total supply
        totalSupply_ = ABDKMathQuad.add(totalSupply_, via);
        //generate event
        emit ViaCashIssued(name, via);
    }

    function finallyRedeem(bytes16 value, bytes32 currency, address party, bytes16 amount) private {
        //only if the issuer's balance of the deposited currency is more than or equal to amount redeemed
        for(uint256 p=0; p<cashbalances[address(this)].length; p++){
            //check if currency in which redemption is to be done is available in cash balances
            if(cashbalances[address(this)][p].name == currency){
                //check if currency in which redemption is to be done has sufficient balance
                if(ABDKMathQuad.cmp(cashbalances[address(this)][p].balance, value)==1 || ABDKMathQuad.cmp(cashbalances[address(this)][p].balance, value)==0){
                    //deduct amount to be transferred from cash balance
                    cashbalances[address(this)][p].balance = ABDKMathQuad.sub(cashbalances[address(this)][p].balance, value);
                    //transfer amount from issuer/sender to seller
                    transfer(party, ABDKMathQuad.toUInt(value));
                    //adjust total supply
                    totalSupply_ = ABDKMathQuad.sub(totalSupply_, amount);
                    //generate event
                    emit ViaCashRedeemed(currency, amount);
                }
            }
        }
    }
    
    //get Via exchange rates from oracle and convert given currency and amount to via cash token
    function convertToVia(bytes16 amount, bytes32 currency, bytes16 ethusd, bytes16 viarate) private returns(bytes16){
        if(currency=="ether"){
            //to first convert amount of ether passed to this function to USD
            bytes16 amountInUSD = ABDKMathQuad.mul(ABDKMathQuad.div(amount,ABDKMathQuad.fromUInt(10^18)),ethusd);
            //to then convert USD to Via-currency if currency of this contract is not USD itself
            if(name!="Via-USD"){
                bytes16 inVia = ABDKMathQuad.mul(amountInUSD, viarate);
                return inVia;
            }
            else{
                return amountInUSD;
            }
        }
        //if currency paid in another via currency
        else{
            bytes16 inVia = viarate;
            return inVia;
        }
    }

    //convert Via-currency (eg, Via-EUR, Via-INR, Via-USD) to Ether or another Via currency
    function convertFromVia(bytes16 amount, bytes32 currency, bytes16 ethusd, bytes16 viarate) private returns(bytes16){
        //if currency to convert from is ether
        if(currency=="ether"){
            bytes16 amountInViaUSD = ABDKMathQuad.mul(amount, viarate);
            bytes16 inEth = ABDKMathQuad.mul(amountInViaUSD, ABDKMathQuad.div(ABDKMathQuad.fromUInt(1), ethusd));
            return inEth;
        }
        //else convert to another via currency
        else{
            return ABDKMathQuad.mul(viarate, amount);
        }
    }

}
