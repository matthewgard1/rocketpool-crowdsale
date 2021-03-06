pragma solidity ^0.4.10;
import "./base/Owned.sol";
import "./base/StandardToken.sol";
import "./interface/SalesAgentInterface.sol";
import "./lib/Arithmetic.sol";

/// @title The main Rocket Pool Token (RPL) contract
/// @author David Rugendyke - http://www.rocketpool.net

/*****************************************************************
*   This is the main Rocket Pool Token (RPL) contract. It features
*   Smart Agent compatibility. The Sale Agent is a new type of 
*   contract that can authorise the minting of tokens on behalf of
*   the traditional ERC20 token contract. This allows you to 
*   distribute your ICO tokens through multiple Sale Agents, 
*   at various times, of various token quantities and of varying
*   fund targets. Once you’ve written a new Sale Agent contract,
*   you can register him with the main ERC20 token contract, 
*   he’s then permitted to sell it’s tokens on your behalf using
*   guidelines such as the amount of tokens he’s allowed to sell, 
*   the maximum ether he’s allowed to raise, the start block and
*   end blocks he’s allowed to sell between and more.
/****************************************************************/

contract RocketPoolToken is StandardToken, Owned {

     /**** Properties ***********/

    string public name = 'Rocket Pool Token';
    string public symbol = 'RPL';
    string public version = "1.0";
    // Set our token units
    uint256 public constant decimals = 18;
    uint256 public exponent = 10**decimals;
    uint256 public totalSupply = 0;                             // The total of tokens currently minted by sales agent contracts    
    uint256 public totalSupplyCap = 50 * (10**6) * exponent;    // 50 Million tokens                                 
    
    
    /*** Sale Addresses *********/
       
    mapping (address => salesAgent) private salesAgents;   // Our contract addresses of our sales contracts 
    address[] private salesAgentsAddresses;                // Keep an array of all our sales agent addresses for iteration

    /*** Structs ***************/
             
    struct salesAgent {                     // These are contract addresses that are authorised to mint tokens
        address saleContractAddress;        // Address of the contract
        bytes32 saleContractType;           // Type of the contract ie. presale, crowdsale 
        uint256 targetEthMax;               // The max amount of ether the agent is allowed raise
        uint256 targetEthMin;               // The min amount of ether to raise to consider this contracts sales a success
        uint256 tokensLimit;                // The maximum amount of tokens this sale contract is allowed to distribute
        uint256 tokensMinted;               // The current amount of tokens minted by this agent
        uint256 minDeposit;                 // The minimum deposit amount allowed
        uint256 maxDeposit;                 // The maximum deposit amount allowed
        uint256 startBlock;                 // The start block when allowed to mint tokens
        uint256 endBlock;                   // The end block when to finish minting tokens
        uint256 contributionLimit;          // The max ether amount per account that a user is able to pledge, passing 0 means unlimited
        address depositAddress;             // The address that receives the ether for that sale contract
        bool depositAddressCheckedIn;       // The address that receives the ether for that sale contract must check in with its sale contract to verify its a valid address that can interact
        bool finalised;                     // Has this sales contract been completed and the ether sent to the deposit address?
        bool exists;                        // Check to see if the mapping exists
    }

    /*** Events ****************/

    event mintToken(address _agent, address _address, uint256 _value);
  
    /*** Tests *****************/

    event FlagUint(uint256 flag);
    event FlagAddress(address flag);

    
    /*** Modifiers *************/

    /// @dev Only allow access from the latest version of a sales contract
    modifier isSalesContract(address _sender) {
        // Is this an authorised sale contract?
        assert(salesAgents[_sender].exists == true);
        _;
    }

    
    /**** Methods ***********/

    /// @dev RPL Token Init
    function RocketPoolToken() {}


    // @dev General validation for a sales agent contract receiving a contribution, additional validation can be done in the sale contract if required
    // @param _sender The address sent the contribution
    // @param _value The value of the contribution in wei
    // @return A boolean that indicates if the operation was successful.
    function validateContribution(address _sender, uint256 _value) isSalesContract(msg.sender) returns (bool) {
        // Get an instance of the sale agent contract
        SalesAgentInterface saleAgent = SalesAgentInterface(msg.sender);
        // Did they send anything?
        assert(_value > 0);  
        // Check the depositAddress has been verified by the account holder
        assert(salesAgents[msg.sender].depositAddressCheckedIn == true);
        // Check if we're ok to receive contributions, have we started?
        assert(block.number > salesAgents[msg.sender].startBlock);       
        // Already ended? Or if the end block is 0, it's an open ended sale until finalised by the depositAddress
        assert(block.number < salesAgents[msg.sender].endBlock || salesAgents[msg.sender].endBlock == 0); 
        // Is it above the min deposit amount?
        assert(_value >= salesAgents[msg.sender].minDeposit); 
        // Is it below the max deposit allowed?
        assert(_value <= salesAgents[msg.sender].maxDeposit);       
        // Does this deposit put it over the max target ether for the sale contract?
        assert((saleAgent.contributedTotal() + _value) <= salesAgents[msg.sender].targetEthMax);       
        // Max sure the user has not exceeded their ether allocation - setting 0 means unlimited
        if(salesAgents[msg.sender].contributionLimit > 0) {
            // Get the users contribution so far
            assert((saleAgent.getContributionOf(_sender) + _value) <= salesAgents[msg.sender].contributionLimit);   
        }
        // All good
        return true;
    }


    // @dev General validation for a sales agent contract that requires the user claim the tokens after the sale has finished
    // @param _sender The address sent the request
    // @return A boolean that indicates if the operation was successful.
    function validateClaimTokens(address _sender) isSalesContract(msg.sender) returns (bool) {
        // Get an instance of the sale agent contract
        SalesAgentInterface saleAgent = SalesAgentInterface(msg.sender);
        // Must have previously contributed
        assert(saleAgent.getContributionOf(_sender) > 0); 
        // Sale contract completed
        assert(block.number > salesAgents[msg.sender].endBlock);  
        // All good
        return true;
    }
    

    // @dev Mint the Rocket Pool Tokens (RPL)
    // @param _to The address that will receive the minted tokens.
    // @param _amount The amount of tokens to mint.
    // @return A boolean that indicates if the operation was successful.
    function mint(address _to, uint _amount) isSalesContract(msg.sender) returns (bool) {
        // Check if we're ok to mint new tokens, have we started?
        // We dont check for the end block as some sale agents mint tokens during the sale, and some after its finished (proportional sales)
        assert(block.number > salesAgents[msg.sender].startBlock);   
        // Check the depositAddress has been verified by the designated account holder that will receive the funds from that agent
        assert(salesAgents[msg.sender].depositAddressCheckedIn == true);
        // No minting if the sale contract has finalised
        assert(salesAgents[msg.sender].finalised == false);
        // Check we don't exceed the assigned tokens of the sale agent
        assert(salesAgents[msg.sender].tokensLimit >= salesAgents[msg.sender].tokensMinted + _amount);
        // Verify ok balances and values
        assert(_amount > 0 && (balances[_to] + _amount) > balances[_to]);
        // Check we don't exceed the supply limit
        assert((totalSupply + _amount) <= totalSupplyCap);
        // Ok all good
        balances[_to] += _amount;
        // Add to the total minted for that agent
        salesAgents[msg.sender].tokensMinted += _amount;
        // Add to the overall total minted
        totalSupply += _amount;
        // Fire the event
        mintToken(msg.sender, _to, _amount);
        // Completed
        return true; 
    }

    
    /// @dev Set the address of a new crowdsale/presale contract agent if needed, usefull for upgrading
    /// @param _saleAddress The address of the new token sale contract
    /// @param _saleContractType Type of the contract ie. presale, crowdsale, quarterly
    /// @param _targetEthMax The max amount of ether the agent is allowed raise
    /// @param _targetEthMin The min amount of ether to raise to consider this contracts sales a success
    /// @param _tokensLimit The maximum amount of tokens this sale contract is allowed to distribute
    /// @param _minDeposit The minimum deposit amount allowed
    /// @param _maxDeposit The maximum deposit amount allowed
    /// @param _startBlock The start block when allowed to mint tokens
    /// @param _endBlock The end block when to finish minting tokens
    /// @param _contributionLimit The max ether amount per account that a user is able to pledge, passing 0 means unlimited
    /// @param _depositAddress The address that receives the ether for that sale contract
    function setSaleAgentContract(
        address _saleAddress, 
         string _saleContractType, 
        uint256 _targetEthMax, 
        uint256 _targetEthMin, 
        uint256 _tokensLimit, 
        uint256 _minDeposit,
        uint256 _maxDeposit,
        uint256 _startBlock, 
        uint256 _endBlock, 
        uint256 _contributionLimit, 
        address _depositAddress
    ) 
    // Only the owner can register a new sale agent
    public onlyOwner  
    {
        if(_saleAddress != 0x0 && _depositAddress != 0x0) {
            // Count all the tokens currently available through our agents
            uint256 currentAvailableTokens = 0;
            for(uint256 i=0; i < salesAgentsAddresses.length; i++) {
               currentAvailableTokens += salesAgents[salesAgentsAddresses[i]].tokensLimit;
            }
            // If tokensLimit is set to 0, it means assign the rest of the available tokens
            _tokensLimit = _tokensLimit <= 0 ? totalSupplyCap - currentAvailableTokens : _tokensLimit;
            // Can we cover this lot of tokens for the agent if they are all minted?
            assert(_tokensLimit > 0 && totalSupplyCap >= (currentAvailableTokens + _tokensLimit));
            // Make sure the min deposit is less than or equal to the max
            assert(_minDeposit <= _maxDeposit);
            // Make sure the supplied contribution limit is not more than the targetEthMax - 0 means unlimited
            if(_contributionLimit > 0) {
                assert(_contributionLimit <= _targetEthMax);
            }
            // Add the new sales contract
            salesAgents[_saleAddress] = salesAgent({
                saleContractAddress: _saleAddress,       
                saleContractType: sha3(_saleContractType),         
                targetEthMax: _targetEthMax,
                targetEthMin: _targetEthMin,   
                tokensLimit: _tokensLimit,  
                tokensMinted: 0,
                minDeposit: _minDeposit,
                maxDeposit: _maxDeposit,            
                startBlock: _startBlock,                 
                endBlock: _endBlock,  
                contributionLimit: _contributionLimit,                 
                depositAddress: _depositAddress, 
                depositAddressCheckedIn: false,  
                finalised: false,     
                exists: true                      
            });
            // Store our agent address so we can iterate over it if needed
            salesAgentsAddresses.push(_saleAddress);
        }else{
            throw;
        }
    }


    /// @dev Sets the contract sale agent process as completed, that sales agent is now retired
    function setSaleContractFinalised(address _sender) isSalesContract(msg.sender) public returns(bool)  {
        // Get an instance of the sale agent contract
        SalesAgentInterface saleAgent = SalesAgentInterface(msg.sender);
        // Finalise the crowdsale funds
        assert(!salesAgents[msg.sender].finalised);                       
        // The address that will receive this contracts deposit, should match the original senders
        assert(salesAgents[msg.sender].depositAddress == _sender);            
        // If the end block is 0, it means an open ended crowdsale, once it's finalised, the end block is set to the current one
        if(salesAgents[msg.sender].endBlock == 0) {
            salesAgents[msg.sender].endBlock = block.number;
        }
        // Not yet finished?
        assert(block.number >= salesAgents[msg.sender].endBlock);         
        // Not enough raised?
        assert(saleAgent.contributedTotal() >= salesAgents[msg.sender].targetEthMin);
        // We're done now
        salesAgents[msg.sender].finalised = true;
        // All good
        return true;
    }


    /// @dev Verifies if the current address matches the depositAddress
    /// @param _verifyAddress The address to verify it matches the depositAddress given for the sales agent
    function setSaleContractDepositAddressVerified(address _verifyAddress) isSalesContract(msg.sender) public  {
        // Check its verified
        assert(salesAgents[msg.sender].depositAddress == _verifyAddress && _verifyAddress != 0x0);
        // Ok set it now
        salesAgents[msg.sender].depositAddressCheckedIn = true;
    }

    /// @dev Returns true if this sales contract has finalised
    /// @param _salesAgentAddress The address of the token sale agent contract
    function getSaleContractIsFinalised(address _salesAgentAddress) isSalesContract(_salesAgentAddress) public returns(bool)  {
        return salesAgents[_salesAgentAddress].finalised;
    }

    /// @dev Returns the min target amount of ether the contract wants to raise
    /// @param _salesAgentAddress The address of the token sale agent contract
    function getSaleContractTargetEtherMin(address _salesAgentAddress) isSalesContract(_salesAgentAddress) public returns(uint256)  {
        return salesAgents[_salesAgentAddress].targetEthMin;
    }

    /// @dev Returns the max target amount of ether the contract can raise
    /// @param _salesAgentAddress The address of the token sale agent contract
    function getSaleContractTargetEtherMax(address _salesAgentAddress) isSalesContract(_salesAgentAddress) public returns(uint256)  {
        return salesAgents[_salesAgentAddress].targetEthMax;
    }

    /// @dev Returns the address where the sale contracts ether will be deposited
    /// @param _salesAgentAddress The address of the token sale agent contract
    function getSaleContractDepositAddress(address _salesAgentAddress) isSalesContract(_salesAgentAddress) public returns(address)  {
        return salesAgents[_salesAgentAddress].depositAddress;
    }

    /// @dev Returns the true if the sale agents deposit address has been verified
    /// @param _salesAgentAddress The address of the token sale agent contract
    function getSaleContractDepositAddressVerified(address _salesAgentAddress) isSalesContract(_salesAgentAddress) public returns(bool)  {
        return salesAgents[_salesAgentAddress].depositAddressCheckedIn;
    }

    /// @dev Returns the start block for the sale agent
    /// @param _salesAgentAddress The address of the token sale agent contract
    function getSaleContractStartBlock(address _salesAgentAddress) isSalesContract(_salesAgentAddress) public returns(uint256)  {
        return salesAgents[_salesAgentAddress].startBlock;
    }

    /// @dev Returns the start block for the sale agent
    /// @param _salesAgentAddress The address of the token sale agent contract
    function getSaleContractEndBlock(address _salesAgentAddress) isSalesContract(_salesAgentAddress) public returns(uint256)  {
        return salesAgents[_salesAgentAddress].endBlock;
    }

    /// @dev Returns the max tokens for the sale agent
    /// @param _salesAgentAddress The address of the token sale agent contract
    function getSaleContractTokensLimit(address _salesAgentAddress) isSalesContract(_salesAgentAddress) public returns(uint256)  {
        return salesAgents[_salesAgentAddress].tokensLimit;
    }

    /// @dev Returns the token total currently minted by the sale agent
    /// @param _salesAgentAddress The address of the token sale agent contract
    function getSaleContractTokensMinted(address _salesAgentAddress) isSalesContract(_salesAgentAddress) public returns(uint256)  {
        return salesAgents[_salesAgentAddress].tokensMinted;
    }

    /// @dev Returns the per account contribution limit for the sale agent
    /// @param _salesAgentAddress The address of the token sale agent contract
    function getSaleContractContributionLimit(address _salesAgentAddress) isSalesContract(_salesAgentAddress) public returns(uint256)  {
        return salesAgents[_salesAgentAddress].contributionLimit;
    }
    
}
