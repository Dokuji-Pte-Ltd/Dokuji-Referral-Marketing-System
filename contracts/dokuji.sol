pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
// import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

abstract contract TokenFactory {
    function create(uint contractType , string memory name, string memory symbol) virtual public returns(address);
} 

abstract contract Token is IERC721 {
    function mint(address _address, uint256 _amount) virtual public;
    function burn(address _address, uint256 _amount) virtual public;
    function setBaseURI(string memory _baseUri) virtual public;
}

interface IWETH {
    function withdraw(uint wad) external;
}

interface IRouter {

    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

}

interface IERC721Receiver {
    /**
     * @dev Whenever an {IERC721} `tokenId` token is transferred to this contract via {IERC721-safeTransferFrom}
     * by `operator` from `from`, this function is called.
     *
     * It must return its Solidity selector to confirm the token transfer.
     * If any other value is returned or the interface is not implemented by the recipient, the transfer will be reverted.
     *
     * The selector can be obtained in Solidity with `IERC721Receiver.onERC721Received.selector`.
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

interface PayBackCollection {
    function getPayBackPercent(address addr) external returns (uint);
}


/// @title Dokuji Protocol
/// @author Dokuji
/// @notice You can make P2P swap of ERC20 and ERC721, transfer tokens safely
contract Dokuji is Ownable, ReentrancyGuard, IERC721Receiver {

    // using SafeERC20 for IERC20;
 

    /// *******************************************
    /// structs
    /// *******************************************

    // Could contain several nfts, and other fungible tokens
    struct Composite {
        address[] give;
        uint[] amountGiveOrTokenID;
        //uint refNonce; //referance on previous order. In case when user create a cuouter offer. 
        bool temporary; // this field is used for case when this contract mint's the composite token for the user but holds it to skip approval
        bool needUnwrap; // this field indicates that composite nft should unwrap tokens contained inside in moment of sale complete
    }

    struct Order {
        address give; // maker
        address get; // taker
        address owner; // order owner
        address buyer; // who can buy. if 0 address anyone can buy. if specific then only specific user can buy
        uint16 percentFee; // fee should be attached to the order
        uint amountGiveOrTokenID; // maker amount
        uint amountGetOrTokenID; // taker amount
        uint nonce; // always unique and incremental +1 (common) - created by contract
        uint created; // created or updated by cancelOrder
        uint deadline;
        address payBackAddress; // payback address 
    }

    // *******************************************
    // structs with implementations (generic)
    // *******************************************

    struct ActiveOrderSet {
        Order[] list;
        uint nonce; // always increased
        mapping(uint => uint) nonceToIndex;
        
    }

    mapping(uint => uint) public nonceToParentNonce; //referance on previous order. In case when user create a cuouter offer. 
    



    /// @notice Library function
    function getFromActiveOrderSet(uint nonce) public view returns (Order memory) {
        return orders.list[orders.nonceToIndex[nonce]];
    }

    /// @notice Library function
    function getActiveOrderLength() public view returns (uint) {
        return orders.list.length;
    }

    
    //mapping(bytes32 => uint) public orderIdToNonce; 

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external pure returns (bytes4) {
        //bytes4 empty;
        //return supportedTokens[operator] == 2 ? this.onERC721Received.selector : empty;
        return this.onERC721Received.selector;
    }

    /// @notice Library function
    function addToActiveOrderSet(address give, address get, address owner, address buyer, uint amountGiveOrTokenID, uint amountGetOrTokenID, uint refNonce, uint duration, uint time, address paybackAddress) private {
        // it becomes publicly visible for users and then they can execute the order
        orders.list.push(Order(give, get, owner, buyer, percentFee, amountGiveOrTokenID, amountGetOrTokenID, orders.nonce, time, block.timestamp + duration, paybackAddress));
        orders.nonceToIndex[orders.nonce] = orders.list.length - 1;
        orders.nonce++;
        //orderIdToNonce[getOrderId(owner, give, amountGiveOrTokenID, time)] = orders.nonce - 1;
        emit PlaceOrder(give, get, owner, buyer, percentFee, amountGiveOrTokenID, amountGetOrTokenID, orders.nonce - 1, time, refNonce, duration);
    }

    /// @notice Library function
    function removeFromActiveOrderSet(uint nonce) private {
        uint index = orders.nonceToIndex[nonce];
        if (index == 0 || index >= orders.list.length) revert OutOfIndex();
        orders.list[index] = orders.list[orders.list.length - 1];
        Order memory order = orders.list[index];
        //orderIdToNonce[getOrderId(order.owner, order.give, order.amountGiveOrTokenID, order.created)] = 0;
        orders.nonceToIndex[order.nonce] = index;
        delete orders.nonceToIndex[nonce];
        delete nonceToParentNonce[nonce];
        orders.list.pop();
    }


    /// *******************************************
    /// storage
    /// *******************************************


    
    /// @notice This list could be used the UI. without using of sabgraph node.
    ActiveOrderSet public orders;

    /// @notice for Composite 
    uint compositeNonce = 1;

    /// @notice the calc formula is amount * percent / 10000. So 10 means 0.1 percent for fungible tokens
    uint16 private percentFee = 10; // platform fee

    // static fee between non fungible tokens
    mapping(address => uint) staticFee;

    /// @notice how much admin earned (admin field)
    mapping(address => uint) public feeEarned;


    /// @notice how much contact owes to people
    mapping(address => uint) private debt;

    // compoiste nfts
    mapping(uint => Composite) public composites;
    

    // *******************************************
    // events
    // *******************************************

    event PlaceOrder(address give, address get, address owner, address buyer, uint16 percentFee, uint amountGive, uint amountGet, uint nonce, uint created, uint refNonce, uint duration);
    
    event BuyOrder(uint nonce, address buyer, bool flag);
    
    event CancelOrder(uint nonce);

    /// *******************************************
    /// errors
    /// *******************************************

    error WrongOwner(address owner, address sender);
    
    error WrongAmount(uint requestedAmount, uint allowedAmount);
    
    error WrongChangedMsgValue(uint real, uint needed);
    
    error OrderIsEmpty();

    error MaximumFeeIs10Percent();

    error OutOfIndex();

    error CannotSentNativeToken();

    error OrderMustBeOlderThan1Week(uint diffSeconds);

    error NothingToExecute();

    error WrongToken(address requested, address actual);

    error UnsupportedToken(address token);

    error OrderIsExpired();

    struct SupportedToken {
        uint8 tokenType;
        uint8 royaltyPercent; 
        address royaltyAddress;
    }

    mapping(address => SupportedToken) public supportedTokens;

    /// @notice Add supported tokens by admin
    /// @param _token Token Address
    /// @param _tokenType 0 when not supported, 1 when erc20, 2 when erc721
    /// @param _royaltyPercent how much percent we pay to creator
    /// @param _royaltyAddress the creator address
    function adjustSupportedToken(address _token, uint8 _tokenType, uint8 _royaltyPercent, address _royaltyAddress) external onlyOwner {
        
        supportedTokens[_token] = SupportedToken(_tokenType, _royaltyPercent, _royaltyAddress);
    }

    /// *******************************************
    /// Admin actions
    /// *******************************************

    Token public immutable nft; 
    
    PayBackCollection immutable public payBackCollection;

    /// @notice Constructor
    /// @param _tokenFactory Token generator
    /// @param _payBackCollection Holders of these NFTs can attach themeself to trade and get the payback
    constructor(address _tokenFactory, PayBackCollection _payBackCollection) {
        // Create NFT Contract from existing factory owned by this contract
        nft = Token(TokenFactory(_tokenFactory).create(1, "Dokuji", "CNFT"));
        nft.setBaseURI("/composites");

        // swap fee
        staticFee[address(nft)] = 1 ether;
        Order memory _order;
        orders.list.push(_order);
        orders.nonce = 1; //start nonce
        supportedTokens[address(nft)] = SupportedToken(2, 0, address(0));
        supportedTokens[address(0)] = SupportedToken(3, 0, address(0));
        payBackCollection = _payBackCollection;

        
    }
 
    /// @notice Change Fee (only owner can call)
    /// @param feeType Type of fee
    /// @param _token For fee type 1
    /// @param _value New fee. Must be less then 1000 (10 percent) in case of type 0, amount in case of 1
    function setFee(uint8 feeType, address _token, uint256 _value) external onlyOwner {
        if (feeType == 0) {
            if (_value >= 1000) revert MaximumFeeIs10Percent(); // maximum fee to save user's expectations
            percentFee = uint16(_value);
        } else if (supportedTokens[_token].tokenType == 2) {
            staticFee[_token] = _value;
        }
    }
    

    /// @notice We calculate huw much tokens we can fairly withdraw from the contract and withdraw (only owner can call)
    /// @param _token Specify withdrawable token
    function withdraw(address _token) external onlyOwner {
        if (isERC721(_token)) revert NothingToExecute();
        uint balance = _token == address(0) ? address(this).balance : IERC20(_token).balanceOf(address(this));
        uint withdrawable = balance - debt[_token];
        _sendAsset(_token, msg.sender, withdrawable, false);
    }

    /// @notice Cancel the order by the admin in case when order is too old (only owner can call)
    /// @param nonce Unique identifier of the order (always incremental)
    function cancelOrderByAdmin(uint nonce) external onlyOwner nonReentrant {
        
        Order memory order = getFromActiveOrderSet(nonce);
        
        if (order.owner == address(0x0)) revert NothingToExecute();
        if (order.created + 604800 > block.timestamp) revert OrderMustBeOlderThan1Week((order.created + 604800) - block.timestamp);
        
        _sendAsset(order.give, order.owner, order.amountGiveOrTokenID, true);
        //Fixed bug #06 (msg.sender is replaced with order.owner because we give away token back to owner
        _unwrapIfNeeded(order.owner, order);
        removeFromActiveOrderSet(order.nonce);

        emit CancelOrder(nonce);
    }

    // *******************************************
    // common actions and getters
    // *******************************************


    /// @notice Check native token or not and perform the appropriate send
    /// @param _token Specify withdrawable token
    /// @param _recipient Target address
    /// @param _amount Target amount
    /// @param _reduceDebt - reduce the debt of contract to external users
    function _sendAsset(address _token, address _recipient, uint _amount, bool _reduceDebt) private {
        if (isERC721(_token)) {
            //IERC721(_token).approve(_recepient, _amount);
            IERC721(_token).safeTransferFrom(address(this), _recipient, _amount);
        } else if (_amount > 0) {
            if (_token == address(0x0)) {
                _safeTransfer(_recipient, _amount);
            }
            else {
                IERC20(_token).transfer(_recipient, _amount);
            }

            if (_reduceDebt)
                _adjustDebt(_token, true, _amount);
        }
        

        

    }


    /// @notice Calculate Fee based on order
    /// @param order Current order
    /// @param amount Trade Amount
    function getFee(address token, Order memory order, uint amount, bool royaltyPay) private view returns (uint) {
        if (isERC721(token)) return 0;
        uint platformFee = (amount * order.percentFee / 10000);
        uint royaltyFee = !royaltyPay ? 0 : (amount * supportedTokens[token].royaltyPercent / 10000);
        return platformFee + royaltyFee;
    }

    function _unwrapIfNeeded(address msg_sender, Order memory order) private {
        if (order.give == address(nft) && composites[order.amountGiveOrTokenID].needUnwrap == true) {
            // unwrap composite nft to real tokens
            _burn(msg_sender, order.amountGiveOrTokenID);
        }
    }

    /// @notice Cancel the order by the user. We can cancel partially (if too call trade_amountGive = 0) then timestamp should be updated only
    /// @param nonce Unique identifier of the order (always incremental)
    function cancelOrder(uint nonce) external nonReentrant {
        
        Order memory order = getFromActiveOrderSet(nonce);
        
        if (order.owner != msg.sender) revert WrongOwner(order.owner, msg.sender);

        _sendAsset(order.give, order.owner, order.amountGiveOrTokenID, true);

        _unwrapIfNeeded(msg.sender, order);

        removeFromActiveOrderSet(order.nonce);
        emit CancelOrder(nonce);

    }

    /*
    function getOrderId(address owner, address token, uint tokenId, uint created) public pure returns(bytes32 result){
      return keccak256(abi.encodePacked(owner, token, tokenId, created));
    } 
    */ 

    /// @notice Update the order by the user. We can cancel partially (if too call trade_amountGive = 0) then timestamp should be updated only
    /// @param nonce Unique identifier of the order (always incremental)
    /// @param newGet new token user wants get
    /// @param newAmountGet new token amount
    function updateOrder(uint nonce, address newGet, uint newAmountGet) external {
        
        //Added recommened condition #5
        if (supportedTokens[newGet].tokenType == 0) revert UnsupportedToken(newGet);

        Order memory order = getFromActiveOrderSet(nonce);

        //Added recommened condition #5
        if (order.deadline < block.timestamp) revert OrderIsExpired();
        
        if (order.owner != msg.sender) revert WrongOwner(order.owner, msg.sender);

        removeFromActiveOrderSet(order.nonce);
        addToActiveOrderSet(order.give, newGet, msg.sender, order.buyer, order.amountGiveOrTokenID, newAmountGet, 0, order.deadline, block.timestamp, order.payBackAddress);
        
        emit CancelOrder(nonce);
    }

    
    /// @notice Make a transfer and check real sent value diff
    /// @param token IERC20 token
    /// @param from Who spends token
    /// @param amountOrTokenID Transfer Amount 
    /// @return (diff, changed_msg_value)
    function _receiveAsset(uint changable_msg_value, address from , address token, uint amountOrTokenID) private returns (uint, uint) {
        address to = address(this);
        if (token == address(0)) {
            if (changable_msg_value < amountOrTokenID) revert WrongChangedMsgValue(changable_msg_value, amountOrTokenID);
            changable_msg_value -= amountOrTokenID;
            return (0, changable_msg_value);
        } else if (isERC721(token)) {
            
            // process specific case when this contract is owner of the contract but temporary to skip approval state
            if (token == address(nft) && nft.ownerOf(amountOrTokenID) == address(this) && composites[amountOrTokenID].temporary ) {
                composites[amountOrTokenID].temporary = false; // remove the record
            } else
                IERC721(token).safeTransferFrom(from, to, amountOrTokenID);
            return (0, changable_msg_value);
        }
        else {
            uint balanceBefore = IERC20(token).balanceOf(address(this));
            IERC20(token).transferFrom(from, to, amountOrTokenID);
            uint balanceAfter = IERC20(token).balanceOf(address(this));
            return (amountOrTokenID - (balanceAfter - balanceBefore), changable_msg_value);
        }
    }

    /// @notice Burn Composite NFT
    /// @param nonce NFT id
    function burn(uint nonce) external nonReentrant {
        _burn(msg.sender, nonce);
    }


    /// @notice Burn Composite NFT
    /// @param nonce NFT id
    function _burn(address msg_sender, uint nonce) private {
        
        Composite memory _composite = composites[nonce];
        
        address owner = nft.ownerOf(nonce);

        if (msg_sender != owner && msg_sender != address(this)) revert WrongOwner(owner, msg_sender);
        
        uint length = _composite.give.length;
        
        if (length == 0) revert NothingToExecute();

        for (uint i=0; i < length;) {
            
            _sendAsset(_composite.give[i], owner, _composite.amountGiveOrTokenID[i], true);

            unchecked {
                i++;
            }

        }

        nft.burn(owner, nonce);

        delete composites[nonce];

    }

    /// @notice Update contract's debt to the user
    /// @param token ERC20 or ERC721
    /// @param minus - Should we reduce debt? otherwise add to debt
    /// @param amountOrTokenId - How much to adjust or tokenID
    function _adjustDebt(address token, bool minus, uint amountOrTokenId) private {
        if (!isERC721(token))
            if (minus) {
                debt[token] -= amountOrTokenId;
            } else {
                debt[token] += amountOrTokenId;
            }
    } 

    /// @notice Mint Composite NFT
    /// @param tokens Token Addresses (fungible and non-fungible)
    /// @param amountOrTokenIds Amounts (fungible) of TokenIDs (non-fungible)
    function mint(address[] calldata tokens, uint[] memory amountOrTokenIds) external payable nonReentrant {
        uint changeable_msg_value = _mint(tokens, amountOrTokenIds, msg.value, msg.sender, msg.sender);
        _refundIfNeeded(msg.sender, changeable_msg_value);
    }

    /// @notice Mint Composite NFT
    /// @dev The length of tokens array could be less than length of amountOrTokenIds. Because last token address could be considered as repetitive for next values. It is usefull when use wants to offer several nfts of the same collection.
    /// @param tokens Token Addresses (fungible and non-fungible)
    /// @param amountOrTokenIds Amounts (fungible) of TokenIDs (non-fungible)
    /// @param sender How is sender
    /// @param receiver Holder of coins
    function _mint(address[] calldata tokens, uint[] memory amountOrTokenIds, uint changeable_msg_value, address sender, address receiver) private returns (uint) {
         
        uint length = amountOrTokenIds.length;

        if (length == 0) revert NothingToExecute();

        for (uint i=0; i < length;) {
            //
            uint j = tokens.length - 1  < i ? i : tokens.length - 1;
            (uint diff, uint change_msg_value2) = _receiveAsset(changeable_msg_value, sender, tokens[j], amountOrTokenIds[i]);
            
            amountOrTokenIds[i] -= diff;
            changeable_msg_value = change_msg_value2;
            _adjustDebt(tokens[i], false, amountOrTokenIds[i]);
            
            unchecked {
                i++;
            }
        }

        composites[compositeNonce] = Composite(tokens, amountOrTokenIds, false, false);
    
        nft.mint(receiver, compositeNonce);
    
        compositeNonce++;

        return changeable_msg_value;
    }

    // @notice accept counter offer and cancel the previous order
    // @param nonce offer nonce (order)
    // @param nonce should pay royalties
    function acceptOffer(uint nonce, bool royaltyPay) external payable nonReentrant {
        // Order memory order = getFromActiveOrderSet(nonce);
        //if (order.give != address(nft)) revert WrongToken(order.give, address(nft));

        uint refNonce = nonceToParentNonce[nonce];
        if (refNonce == 0) revert OutOfIndex();
        Order memory refOrder = getFromActiveOrderSet(refNonce);
        if (refOrder.owner != msg.sender) revert WrongOwner(refOrder.owner, msg.sender);
        //forget about previous order
        _buyOrder(msg.value, msg.sender, false, nonce, royaltyPay);
        removeFromActiveOrderSet(refNonce);

    }

    

    /// @notice Make a counter offer and transfor the array of tokens into internal nft (if needed)
    /// @param refNonce Order ID
    /// @param gives Token Addresses (fungible and non-fungible)
    /// @param amountOrTokenIds Amounts (fungible) of TokenIDs (non-fungible)
    function makeOfferFromOrder(uint refNonce, address[] calldata gives, uint[] calldata amountOrTokenIds) external payable nonReentrant {
        Order memory order = getFromActiveOrderSet(refNonce);

        if (order.owner == address(0)) revert OutOfIndex();

        address give;

        uint amountOrTokenId;
        uint changable_msg_value = msg.value;

        if (amountOrTokenIds.length == 1) {
            give = gives[0];
            amountOrTokenId = amountOrTokenIds[0];
        }
        else {
            changable_msg_value = _mint(gives, amountOrTokenIds, changable_msg_value, msg.sender, address(this));
            give = address(nft);
            composites[compositeNonce - 1].temporary = true;
            //Bug fix: Auditors case #1
            composites[compositeNonce - 1].needUnwrap = true;
            
            amountOrTokenId = compositeNonce - 1;
        }
        
        _makeOrder(give, order.give, changable_msg_value, msg.sender, amountOrTokenId, order.amountGiveOrTokenID, order.owner, order.nonce, order.deadline, order.payBackAddress);
        
        nonceToParentNonce[orders.nonce - 1] = refNonce;

    }

    /// @notice Make an new order
    /// @param give - token address or 0x address. if 0x address then it's native coin
    /// @param get - token address or 0x address. if 0x address then it's native coin
    /// @param amountGive - Maker amount
    /// @param amountGet - Taker Amount
    /// @param buyer - Who can buy. 0x0 address when anyone can buy
    /// @param payBackAddress - Address of payback NFT holder
    function makeOrder(address give, address get, uint amountGive, uint amountGet, address buyer, uint duration, address payBackAddress ) external payable nonReentrant {
        _makeOrder(give, get, msg.value, msg.sender, amountGive, amountGet, buyer, 0, duration, payBackAddress);
    } 

    /// @notice Make an new order
    /// @param give - token address or 0x address. if 0x address then it's native coin
    /// @param get - token address or 0x address. if 0x address then it's native coin
    /// @param msg_sender - who spends token
    /// @param amountGive - Maker amount
    /// @param amountGet - Taker Amount
    /// @param buyer - Who can buy. 0x0 address when anyone can buy
    function _makeOrder(address give, address get, uint msg_value, address msg_sender, uint amountGive, uint amountGet, address buyer, uint refNonce, uint duration, address payBackAddress) private {
        
        if (supportedTokens[give].tokenType == 0) revert UnsupportedToken(give);
        if (supportedTokens[get].tokenType == 0) revert UnsupportedToken(get);

        (uint diff, uint changeable_msg_value) = _receiveAsset(msg_value, msg_sender, give, amountGive);

        if (diff > 0) revert WrongAmount(amountGive, amountGive - diff);
    
        _refundIfNeeded(msg_sender, changeable_msg_value);

        _adjustDebt(give, false, amountGive);
        
        // it becomes publicly visible for users and then they can execute the order
        addToActiveOrderSet(give, get, msg_sender, buyer, amountGive, amountGet, refNonce, duration, block.timestamp, payBackAddress);
    }

    /// @notice Buy Order with any token. Only for case when give is nft, get is fungible
    /// @param nonce - unique nonce of the trade
    /// @param router - dex's router
    /// @param path Conversion Path
    function buyTokenWithSwap(uint256 nonce, IRouter router, address[] memory path, uint amount, bool royaltyPay) external payable nonReentrant {
        
        (uint diff, uint changeable_msg_value) = _receiveAsset(msg.value, msg.sender, path[0], amount);
        amount -= diff;

        _refundIfNeeded(msg.sender, changeable_msg_value);

        Order memory order = getFromActiveOrderSet(nonce);

        if (order.deadline < block.timestamp) revert OrderIsExpired();

        //if (path[path.length -1] != order.get) revert WrongToken(order.get, path[path.length -1]);

        if (order.amountGetOrTokenID == 0) revert OrderIsEmpty();  
        
        // Issue #02 Applied recommendation
        if (order.buyer != address(0) || order.buyer != msg.sender) revert WrongOwner(order.buyer, msg.sender);

        uint amountGetFee =  getFee(order.get, order, order.amountGetOrTokenID, false);
        uint amountGiveFee =  getFee(order.give, order, order.amountGiveOrTokenID, royaltyPay);

        if (path[0] == address(0x0)) {
            _safeTransfer(router.WETH(), amount);
            path[0] = router.WETH();
        }

        address sender = address(this);
        //IERC20 tokenGive = IERC20(order.give == address(0x0) ? router.WETH() : order.give);
        IERC20 tokenGet = IERC20(order.get == address(0x0) ? router.WETH() : order.get);
        uint256 balanceBefore = tokenGet.balanceOf(sender);
        
        IERC20(path[0]).approve(address(router), amount);
        
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount,
            order.amountGetOrTokenID,
            path,
            address(this),
            block.timestamp
        );
    
        uint256 balanceAfter = tokenGet.balanceOf(sender);
        
        
        if (balanceAfter <= balanceBefore) revert WrongAmount(balanceAfter, balanceBefore);
        
        uint bdiff = balanceAfter - balanceBefore;
        
        if (bdiff < order.amountGetOrTokenID) revert WrongAmount(bdiff, order.amountGetOrTokenID);

        //TODO: maybe consider send rest to the buyer

        // Bug fix #02 The WETH interaction is flawed: the contract tries to withdraw diff instead of bDiff in case of order.get = address(0). This will either result in a revert or it will transfer ETHER out which is assigned to other orders. (HIGH severity)
        if (order.get == address(0x0))
            IWETH(router.WETH()).withdraw(bdiff);


        //_buyOrder(0, false, nonce);

        uint amountGet = order.amountGetOrTokenID - amountGetFee;

        _adjustFee(order, order.get, bdiff - amountGet, false);
        _adjustFee(order, order.give, amountGiveFee, royaltyPay);

        _sendAsset(order.get, order.owner, amountGet, false); // have not much BNB to transfer to owner
        //Bug fix: Issue #02 - givetokenisnevertransferredtothebuyer,essentiallyleaving the buyer empty (HIGH severity)
        _sendAsset(order.give, msg.sender, order.amountGiveOrTokenID, true);
        removeFromActiveOrderSet(order.nonce);

        emit BuyOrder(order.nonce, msg.sender, true);
        
    }

    function _refundIfNeeded(address msg_sender, uint msg_value) private {
        if (msg_value >0)
            _safeTransfer(msg_sender, msg_value);
    }

    // @notice Buy Few Orders at once. Anyone can execute this action
    /// @dev If at lesat one order is possible then transaction will be successful
    /// @param nonce  - Unique identifier of the order (always incremental)
    /// @param royaltyPay - should pay royalties
    function buyOrder(uint nonce, bool royaltyPay) external payable nonReentrant {
        _refundIfNeeded(msg.sender, _buyOrder(msg.value, msg.sender, true, nonce, royaltyPay));
    }

    /// @notice Buy Few Orders at once. Anyone can execute this action
    /// @dev If at lesat one order is possible then transaction will be successful
    /// @param nonce - Array - Unique identifier of the order (always incremental)
    /// @param royaltyPay - should pay royalties?
    function buyOrders(uint[] calldata nonce, bool royaltyPay) external payable nonReentrant {
        
        uint msg_value = msg.value;

        // even when some transactions front-runned then other are still executable
        uint skipped = 0;
        
        for (uint i=0; i < nonce.length;) {
            
            unchecked {
                i++;
            }

            if(orders.nonceToIndex[nonce[i - 1]] == 0) {
                
                unchecked {
                    skipped++;
                }
                
                continue;
            }
                
            msg_value = _buyOrder(msg_value, msg.sender, true, nonce[i - 1], royaltyPay);

        }

        //refund
        _refundIfNeeded(msg.sender, msg_value);

        if (skipped == nonce.length) revert NothingToExecute();
               
    }

    /// @notice Send from this smart contract to user
    /// @param receiver - Target address
    /// @param value - Target Amount
    function _safeTransfer(address receiver, uint value) private {
        (bool sent, ) = payable(receiver).call{ value: value }("");
        if (!sent) revert CannotSentNativeToken();
    }

    function isERC721(address token) public view returns (bool) {
        // removed this line because this token is added to supported token in constructor but need to reduce the size of contract
        //if (token == address(nft))
        //    return true;
        return supportedTokens[token].tokenType == 2;
    }

    function getStaticFee(address token) public view returns (uint) {
        return staticFee[token] == 0 ? staticFee[address(0)] : staticFee[token];
    }

    /// @notice Internal buy order. Trust to valid changeable_msg_value
    /// @param changeable_msg_value - Mutable msg.value
    /// @param msg_sender - who spends token
    /// @param chargeGet Should we get tokens from the user or he put it before
    /// @param nonce - Unique identifier of the order (always incremental)
    /// @param royaltyPay - should pay royalty to creator
    function _buyOrder(uint changeable_msg_value, address msg_sender, bool chargeGet, uint nonce, bool royaltyPay) private returns (uint) {
        
        Order memory order = getFromActiveOrderSet(nonce);

        if (order.deadline < block.timestamp) revert OrderIsExpired();

        if ( order.buyer != address(0) && order.buyer != msg_sender) revert WrongOwner(order.buyer, msg_sender);
        
        uint actualAmountGetFee =  getFee(order.get, order, order.amountGetOrTokenID, false);

        uint actualAmountGet = order.amountGetOrTokenID - actualAmountGetFee;

        // only when owner want to get some funds
        if (chargeGet) { 
        
            // balance before and after because we do not trust transfer function

            (uint diff, uint changeable_msg_value2) = _receiveAsset(changeable_msg_value, msg_sender, order.get, order.amountGetOrTokenID);
            
            //if (diff > 0 ) revert WrongAmount(order.amountGetOrTokenID, order.amountGetOrTokenID - diff);
            if (diff > 0 ) revert WrongAmount(order.amountGetOrTokenID, diff);
            changeable_msg_value = changeable_msg_value2;
            
        }

        // very important prevent case when NFT is removed
        if (order.owner  == address(0)) revert WrongOwner(order.owner, address(0));

        uint actualAmountGiveFee =  getFee(order.give, order, order.amountGiveOrTokenID, royaltyPay);
        uint actualAmountGive = order.amountGiveOrTokenID - actualAmountGiveFee;

        _sendAsset(order.give, msg_sender, actualAmountGive, true);

        
        _unwrapIfNeeded(msg_sender, order);
        

        _sendAsset(order.get, order.owner, actualAmountGet, false);

    
        // pay static fee
        if (actualAmountGetFee + actualAmountGiveFee == 0) {

            uint fee = getStaticFee(order.get);

            if (changeable_msg_value < fee) revert WrongChangedMsgValue(changeable_msg_value, fee);
            changeable_msg_value -= fee;
            _adjustFee(order, address(0), fee, false);
        } else {
            _adjustFee(order, order.get, actualAmountGetFee, false);
            _adjustFee(order, order.give, actualAmountGiveFee, royaltyPay);
        }
       

        emit BuyOrder(order.nonce, msg_sender, chargeGet);

        removeFromActiveOrderSet(order.nonce);
       
        return changeable_msg_value;
        
    }

    function _adjustFee(Order memory order, address token, uint value, bool royaltyPay) private {
        uint percent = payBackCollection.getPayBackPercent(order.payBackAddress);
        
        if (royaltyPay) {
            // order.percentFee
            uint royaltyFee = value * supportedTokens[token].royaltyPercent / 100;
            value -= royaltyFee;
            //adjust debt Issue 03
            _sendAsset(token, supportedTokens[token].royaltyAddress, royaltyFee, true);
        }
        
        if (percent == 0) {
            feeEarned[token] += value;
        }
        else {
            uint payBackValue = (value * percent / 10000);
            feeEarned[token] += value - payBackValue;
            _sendAsset(token, order.payBackAddress, payBackValue, true);
        }
    }
}
