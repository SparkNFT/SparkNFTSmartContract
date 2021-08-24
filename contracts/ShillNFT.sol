// SPDX-License-Identifier: MIT

pragma solidity >= 0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IERC721Receiver.sol";
import "./IERC721Metadata.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
contract ShillNFT is Context, ERC165, IERC721, IERC721Metadata{
    using Address for address;
    using Counters for Counters.Counter;
    using SafeMath for uint256;
    Counters.Counter private _issueIds;
    // 由于时间关系先写中文注释
    // Issue 用于存储一系列的NFT，他们对应同一个URI，以及一系列相同的属性，在结构体中存储
    // 重要的有royalty_fee 用于存储手续费抽成比例
    // base_royaltyfee 当按照比例计算的手续费小于这个值的时候，取用这个值
    // loss_ratio 当我们在链式mint NFT的时候，我希望能够通过数量的不断增多，强制底部的NFT mint的价格降低
    // 以这样的方式增大其传播性，同时使得上层的NFT具备价值
    // shill_times 代表这个issue中的一个NFT最多能够产出多少份子NFT
    // total_amount 这个issue总共产出了多少份NFT，同时用于新产出的NFT标号，标号从1开始
    // first_sell_price 规定了根节点的NFT mint 子节点的费用，之后所有的子节点mint出新节点的费用不会高于这个值
    struct Issue {
        // The publisher publishes a series of NFTs with the same content and different NFT_id each time.
        // This structure is used to store the public attributes of same series of NFTs.
        uint128 issue_id;
        // Number of NFTs have not been minted in this series
        uint8 royalty_fee;
        uint8 loss_ratio;
        // Used to identify which series it is.
        // Publisher of this series NFTs
        uint64 shill_times;
        uint128 total_amount;
        string ipfs_hash;
        // Metadata json file.
        string name;
        // issue's name
        uint256 base_royaltyfee;
        // List of tokens(address) can be accepted for payment.
        // And specify the min fee should be toke when series of NFTs are sold.
        // If base_royaltyfee[tokens] == 0, then this token will not be accepted.
        // `A token address` can be ERC-20 token contract address or `address(0)`(ETH).
        uint256 first_sell_price;
        // The price should be payed when this series NTFs are minted.
        // 这两个mapping如果存在token_addr看价格是不可以等于0的，如果等于0的话会导致判不支持
        // 由于这个价格是写死的，可能会诱导用户的付款倾向
    }
    // 存储NFT相关信息的结构体
    // father_id存储它父节点NFT的id
    // transfer_price 在决定出售的时候设定，买家调起transferFrom付款并转移
    // shillPrice存储从这个子节点mint出新的NFT的价格是多少
    // 此处可以优化，并不需要每一个节点都去存一个，只需要一层存一个就可以了，但是需要NFT_id调整编号的方式与节点在树上的位置强相关
    // is_on_sale 在卖家决定出售的时候将其设置成true，交易完成时回归false，出厂默认为false
    // remain_shill_times 记录该NFT剩余可以产生的NFT
    struct Edition {
        // Information used to decribe an NFT.
        uint256 NFT_id;
        uint256 father_id;
        // Index of this NFT.
        uint256 transfer_price;
        uint256 shillPrice;
        // The price of the NFT in the transaction is determined before the transaction.
        bool is_on_sale;
        uint64 remain_shill_times;
        // royalty_fee for every transfer expect from or to exclude address, max is 100;
    }
    // 分别存储issue与editions
    mapping (uint256 => Issue) private issues_by_id;
    mapping (uint256 => Edition) private editions_by_id;
    // 每个用户的获利由合约暂存，用户自行claim
    // 也可以自动打到账上，待商议?
    mapping (address => uint256) private profit;
    // 确定价格成功后的事件
    event determinePriceSuccess(
        uint256 NFT_id,
        uint256 transfer_price
    );
    // 确定价格的同时approve买家可以操作owner的NFT
    event determinePriceAndApproveSuccess(
        uint256 NFT_id,
        uint256 transfer_price,
        address to
    );
    // 除上述变量外，该事件还返回根节点的NFTId
    event publishSuccess(
	    string name, 
	    uint128 issue_id,
        uint64 shill_times,
        uint8 royalty_fee,
        uint8 loss_ratio,
        string ipfs_hash,
        uint256 base_royaltyfee,
        uint256 first_sell_price,
        uint256 rootNFTId
    );
    // 子节点mint成功，加入了购买者和NFT_id的关系，可以配合transfer的log一起过滤获取某人的所有NFT_id
    event acceptShillSuccess (
        uint256 NFT_id,
        uint256 father_id,
        uint256 shillPrice,
        address buyer
    );
    event transferSuccess(
        uint256 NFT_id,
        address from,
        address to,
        uint256 transfer_price
    );
    // 获取自己的收益成功
    event claimSuccess(
        address receiver,
        uint256 amount
    );
    // Token name
    string private _name;

    // Token symbol
    string private _symbol;

    // Mapping from token ID to owner address
    mapping(uint256 => address) private _owners;

    // Mapping owner address to token count
    mapping(address => uint256) private _balances;

    // Mapping from token ID to approved address
    mapping(uint256 => address) private _tokenApprovals;

    // Mapping from owner to operator approvals
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // Optional mapping for token URIs
    mapping(uint256 => string) private _tokenURIs;
    //----------------------------------------------------------------------------------------------------
    /**
     * @dev Initializes the contract by setting a `name` and a `symbol` to the token collection.
     */
    constructor() {
        _name = "ShillNFT";
        _symbol = "ShillNFT";
        _issueIds.increment();
    }
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC721Metadata).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /**
     * @dev See {IERC721-balanceOf}.
     */
    function balanceOf(address owner) public view virtual override returns (uint256) {
        require(owner != address(0), "ShillNFT: balance query for the zero address");
        return _balances[owner];
    }

    /**
     * @dev See {IERC721-ownerOf}.
     */
    function ownerOf(uint256 tokenId) public view virtual override returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "ShillNFT: owner query for nonexistent token");
        return owner;
    }

    /**
     * @dev See {IERC721Metadata-name}.
     */
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /**
     * @dev See {IERC721Metadata-symbol}.
     */
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev See {IERC721-approve}.
     */
    function approve(address to, uint256 tokenId) public payable virtual override {
        address owner = ownerOf(tokenId);
        require(to != owner, "ShillNFT: approval to current owner");

        require(
            _msgSender() == owner || isApprovedForAll(owner, _msgSender()),
            "ShillNFT: approve caller is not owner nor approved for all"
        );

        _approve(to, tokenId);
    }

    /**
     * @dev See {IERC721-getApproved}.
     */
    function getApproved(uint256 tokenId) public view virtual override returns (address) {
        require(_exists(tokenId), "ShillNFT: approved query for nonexistent token");

        return _tokenApprovals[tokenId];
    }

    /**
     * @dev See {IERC721-setApprovalForAll}.
     */
    function setApprovalForAll(address operator, bool approved) public virtual override {
        require(operator != _msgSender(), "ShillNFT: approve to caller");
        _operatorApprovals[_msgSender()][operator] = approved;
        emit ApprovalForAll(_msgSender(), operator, approved);
    }

    /**
     * @dev See {IERC721-isApprovedForAll}.
     */
    function isApprovedForAll(address owner, address operator) public view virtual override returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function _baseURI() internal pure returns (string memory) {
        return "https://ipfs.io/ipfs/";
    } /**
     * @dev See {IERC721Metadata-tokenURI}.
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_exists(tokenId), "ShillNFT: URI query for nonexistent token");

        string memory _tokenURI = _tokenURIs[tokenId];
        string memory base = _baseURI();
        return string(abi.encodePacked(base, _tokenURI));
        
    }

    /**
     * @dev Sets `_tokenURI` as the tokenURI of `tokenId`.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function _setTokenURI(uint256 tokenId, string memory _tokenURI) internal virtual {
        require(_exists(tokenId), "ShillNFT: URI set of nonexistent token");
        _tokenURIs[tokenId] = _tokenURI;
    }

    /**
     * @dev Destroys `tokenId`.
     * The approval is cleared when the token is burned.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     *
     * Emits a {Transfer} event.
     */
    function _burn(uint256 tokenId) internal {
        address owner = ownerOf(tokenId);
        // Clear approvals
        _approve(address(0), tokenId);

        _balances[owner] -= 1;
        delete _owners[tokenId];

        if (bytes(_tokenURIs[tokenId]).length != 0) {
            delete _tokenURIs[tokenId];
        }

        emit Transfer(owner, address(0), tokenId);
    }
    /**
     * @dev Determine NFT price before transfer.
     *
     * Requirements:
     * 
     * - `_NFT_id` transferred token id.
     * - `_token_addr` address of the token this transcation used, address(0) represent ETH.
     * - `_price` The amount of `_token_addr` should be payed for `_NFT_id`
     *
     * Emits a {determinePriceSuccess} event, which contains:
     * - `_NFT_id` transferred token id.
     * - `_token_addr` address of the token this transcation used, address(0) represent ETH.
     * - `_price` The amount of `_token_addr` should be payed for `_NFT_id`
     */
     // ？ 这个地方有个问题，按照这篇文章https://gus-tavo-guim.medium.com/public-vs-external-functions-in-solidity-b46bcf0ba3ac
     // 在external函数之中使用calldata进行传参数的gas消耗应该会更少一点
     // 但是大部分地方能看到的都是memory
     
    // publish函数分为这样几个部分
    // 首先检验传入的参数是否正确，是否出现了不符合逻辑的上溢现象
    // 然后获取issueid
    // 接下来调用私有函数去把对应的变量赋值
    // 初始化根节点NFT
    // 触发事件，将数据上到log中
    function publish(
        uint256 _base_royaltyfee,
        uint256 _first_sell_price,
        uint8 _royalty_fee,
        uint8 _loss_ratio,
        uint64 _shill_times,
        string memory _issue_name,
        string memory _ipfs_hash
    ) external {
        require(_royalty_fee <= 100, "ShillNFT: Royalty fee should less than 100.");
        require(_loss_ratio <= 100, "ShillNFT: Loss ratio should less than 100.");
        _issueIds.increment();
        uint128 max_128 = type(uint128).max;
        uint64 max_64 = type(uint64).max;
        require(_shill_times <= max_64, "ShillNFT: Shill_times doesn't fit in 64 bits");
        require((_issueIds.current()) <= max_128, "ShillNFT: Issue id doesn't fit in 128 bits");
        uint128 new_issue_id = uint128(_issueIds.current());
        _publish(
            _issue_name, 
            new_issue_id,
            _shill_times, 
            _royalty_fee, 
            _loss_ratio,
            _base_royaltyfee, 
            _first_sell_price, 
            _ipfs_hash
        );
        uint256 rootNFTId =  _initialRootEdition(new_issue_id);
        emit publishSuccess(
            issues_by_id[new_issue_id].name, 
            issues_by_id[new_issue_id].issue_id,
            issues_by_id[new_issue_id].shill_times,
            issues_by_id[new_issue_id].royalty_fee,
            issues_by_id[new_issue_id].loss_ratio,
            issues_by_id[new_issue_id].ipfs_hash,
            issues_by_id[new_issue_id].base_royaltyfee,
            issues_by_id[new_issue_id].first_sell_price,
            rootNFTId
        );
    }
    function _publish(
        string memory _issue_name,
        uint128 new_issue_id,
        uint64 _shill_times,
        uint8 _royalty_fee,
        uint8 _loss_ratio,
        uint256 _base_royaltyfee,
        uint256 _first_sell_price,
        string memory _ipfs_hash
    ) internal {
        Issue storage new_issue = issues_by_id[new_issue_id];
        new_issue.name = _issue_name;
        new_issue.issue_id = new_issue_id;
        new_issue.royalty_fee = _royalty_fee;
        new_issue.loss_ratio = _loss_ratio;
        new_issue.shill_times = _shill_times;
        new_issue.total_amount = 0;
        new_issue.ipfs_hash = _ipfs_hash;
        new_issue.base_royaltyfee = _base_royaltyfee;
        new_issue.first_sell_price = _first_sell_price;
    }

    function _initialRootEdition(uint128 _issue_id) internal returns (uint256) {
        issues_by_id[_issue_id].total_amount += 1;
        uint128 new_edition_id = issues_by_id[_issue_id].total_amount;
        uint256 new_NFT_id = getNftIdByEditionIdAndIssueId(_issue_id, new_edition_id);
        Edition storage new_NFT = editions_by_id[new_edition_id];
        new_NFT.NFT_id = new_NFT_id;
        new_NFT.transfer_price = 0;
        new_NFT.is_on_sale = false;
        new_NFT.father_id = 0;
        new_NFT.shillPrice = issues_by_id[_issue_id].first_sell_price;
        new_NFT.remain_shill_times = issues_by_id[_issue_id].shill_times;
        _setTokenURI(new_NFT_id, issues_by_id[_issue_id].ipfs_hash);
        _safeMint(msg.sender, new_NFT_id);
        return new_NFT_id;
    }
    // 由于存在loss ratio 我希望mint的时候始终按照比例收税
    // 接受shill的函数，也就是mint新的NFT
    // 传入参数是新的NFT的父节点的NFTid
    // 首先还是检查参数是否正确，同时加入判断以太坊是否够用的检测
    // 如果是根节点就不进行手续费扣款
    // 接下来mintNFT
    // 最后触发事件
    function accepetShill(
        uint256 _NFT_id
    ) public payable {
        require(isEditionExist(_NFT_id), "ShillNFT: This NFT is not exist.");
        require(editions_by_id[_NFT_id].remain_shill_times > 0, "ShillNFT: There is no remain shill times for this NFT.");
        require(msg.value == editions_by_id[_NFT_id].shillPrice, "ShillNFT: not enought ETH");
        uint256 grandFather = editions_by_id[_NFT_id].father_id;
        if (grandFather == 0) {
            profit[ownerOf(_NFT_id)].add(editions_by_id[_NFT_id].shillPrice);
        }
        else {
            profit[ownerOf(_NFT_id)].add(
                editions_by_id[_NFT_id].shillPrice-calculateFee(editions_by_id[_NFT_id].shillPrice, issues_by_id[getIssueIdByNFTId(_NFT_id)].royalty_fee));
            profit[ownerOf(grandFather)].add(
                calculateFee(editions_by_id[_NFT_id].shillPrice, issues_by_id[getIssueIdByNFTId(_NFT_id)].royalty_fee));
        }
        uint256 new_NFT_id = _mintNFT(_NFT_id);

        emit acceptShillSuccess (
            new_NFT_id,
            _NFT_id,
            editions_by_id[_NFT_id].shillPrice,
            msg.sender
        );

    }

    function _mintNFT(
        uint256 _NFT_id
    ) internal returns (uint256) {
        uint128 max_128 = type(uint128).max;
        uint128 _issue_id = getIssueIdByNFTId(_NFT_id);
        issues_by_id[_issue_id].total_amount += 1;
        require(issues_by_id[_issue_id].total_amount < max_128, "ShillNFT: There is no left in this issue.");
        uint128 new_edition_id = issues_by_id[_issue_id].total_amount;
        uint256 new_NFT_id = getNftIdByEditionIdAndIssueId(_issue_id, new_edition_id);
        Edition storage new_NFT = editions_by_id[new_edition_id];
        new_NFT.NFT_id = new_NFT_id;
        new_NFT.remain_shill_times = issues_by_id[_issue_id].shill_times;
        new_NFT.transfer_price = 0;
        new_NFT.father_id = _NFT_id;
        new_NFT.shillPrice = editions_by_id[_NFT_id].shillPrice - calculateFee(editions_by_id[_NFT_id].shillPrice, issues_by_id[_issue_id].loss_ratio);
        new_NFT.is_on_sale = false;
        editions_by_id[_NFT_id].remain_shill_times -= 1;
        _setTokenURI(new_NFT_id, issues_by_id[_issue_id].ipfs_hash);
        _safeMint(msg.sender, new_NFT_id);
        return new_NFT_id;
    }

    /**
     * @dev Determine NFT price before transfer.
     *
     * Requirements:
     * 
     * - `_NFT_id` transferred token id.
     * - `_token_addr` address of the token this transcation used, address(0) represent ETH.
     * - `_price` The amount of `_token_addr` should be payed for `_NFT_id`
     *
     * Emits a {determinePriceSuccess} event, which contains:
     * - `_NFT_id` transferred token id.
     * - `_token_addr` address of the token this transcation used, address(0) represent ETH.
     * - `_price` The amount of `_token_addr` should be payed for `_NFT_id`
     */
     // 设定NFT的转移价格，如果计算手续费后小于base line则强制为base line
    function determinePrice(
        uint256 _NFT_id,
        uint256 _price
    ) public {
        require(isEditionExist(_NFT_id), "ShillNFT: The NFT you want to buy is not exist.");
        require(msg.sender == ownerOf(_NFT_id), "ShillNFT: NFT's price should set by onwer of it.");
        if (calculateFee(_price, getRoyaltyFeeByIssueId(getIssueIdByNFTId(_NFT_id)))  < issues_by_id[getIssueIdByNFTId(_NFT_id)].base_royaltyfee)
            editions_by_id[_NFT_id].transfer_price = issues_by_id[getIssueIdByNFTId(_NFT_id)].base_royaltyfee;
        else 
            editions_by_id[_NFT_id].transfer_price = _price;
        editions_by_id[_NFT_id].is_on_sale = true;
        emit determinePriceSuccess(_NFT_id, _price);
    }

    function determinePriceAndApprove(
        uint256 _NFT_id,
        uint256 _price,
        address _to
    ) public {
        determinePrice(_NFT_id, _price);
        approve(_to, _NFT_id);
    }
    // 将flag在转移后重新设置
    function _afterTokenTransfer (
        uint256 _NFT_id
    ) internal {
        editions_by_id[_NFT_id].transfer_price = 0;
        editions_by_id[_NFT_id].is_on_sale = false;
    }

    function transferFrom(
        address from, 
        address to, 
        uint256 NFT_id
    ) public payable override{
        require(_isApprovedOrOwner(_msgSender(), NFT_id), "ShillNFT: transfer caller is not owner nor approved");
        require(isEditionExist(NFT_id), "ShillNFT: Edition is not exist.");
        require(editions_by_id[NFT_id].is_on_sale, "ShillNFT: This NFT is not on sale.");
        if (editions_by_id[NFT_id].father_id != 0){
            uint256 royalty_amount = calculateFee(editions_by_id[NFT_id].transfer_price, issues_by_id[getIssueIdByNFTId(NFT_id)].royalty_fee);
            if (royalty_amount < issues_by_id[getIssueIdByNFTId(NFT_id)].base_royaltyfee){
                royalty_amount = issues_by_id[getIssueIdByNFTId(NFT_id)].base_royaltyfee;
            }
            if (editions_by_id[NFT_id].transfer_price < royalty_amount)
                editions_by_id[NFT_id].transfer_price = royalty_amount;
            require(msg.value == editions_by_id[NFT_id].transfer_price, "ShillNFT: not enought ETH");
            profit[ownerOf(editions_by_id[NFT_id].father_id)].add(royalty_amount);
            profit[ownerOf(NFT_id)].add(editions_by_id[NFT_id].transfer_price.sub(royalty_amount));
        }
        else 
            profit[ownerOf(NFT_id)].add(editions_by_id[NFT_id].transfer_price);
        _transfer(from, to, NFT_id);
        _afterTokenTransfer(NFT_id);

    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 NFT_id
    ) public payable override{
        require(_isApprovedOrOwner(_msgSender(), NFT_id), "ShillNFT: transfer caller is not owner nor approved");
        require(isEditionExist(NFT_id), "ShillNFT: Edition is not exist.");
        require(editions_by_id[NFT_id].is_on_sale, "ShillNFT: This NFT is not on sale.");
        if (editions_by_id[NFT_id].father_id != 0){
            uint256 royalty_amount = calculateFee(editions_by_id[NFT_id].transfer_price, issues_by_id[getIssueIdByNFTId(NFT_id)].royalty_fee);
            if (royalty_amount < issues_by_id[getIssueIdByNFTId(NFT_id)].base_royaltyfee){
                royalty_amount = issues_by_id[getIssueIdByNFTId(NFT_id)].base_royaltyfee;
            }
            if (editions_by_id[NFT_id].transfer_price < royalty_amount)
                editions_by_id[NFT_id].transfer_price = royalty_amount;
            require(msg.value == editions_by_id[NFT_id].transfer_price, "ShillNFT: not enought ETH");
            profit[ownerOf(editions_by_id[NFT_id].father_id)].add(royalty_amount);
            profit[ownerOf(NFT_id)].add(editions_by_id[NFT_id].transfer_price.sub(royalty_amount));
        }
        else 
            profit[ownerOf(NFT_id)].add(editions_by_id[NFT_id].transfer_price);
        _safeTransfer(from, to, NFT_id, "");
        _afterTokenTransfer(NFT_id);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 NFT_id,
        bytes calldata _data
    ) public payable override {
        safeTransferFrom(from, to, NFT_id);
    }
    /**
     * @dev Transfers `tokenId` from `from` to `to`.
     *  As opposed to {transferFrom}, this imposes no restrictions on msg.sender.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - `tokenId` token must be owned by `from`.
     *
     * Emits a {Transfer} event.
     */
    function _transfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual {
        require(ownerOf(tokenId) == from, "ShillNFT: transfer of token that is not own");
        require(to != address(0), "ShillNFT: transfer to the zero address");

        // Clear approvals from the previous owner
        _approve(address(0), tokenId);

        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;

        emit Transfer(from, to, tokenId);
    }
    function claimProfit() public {
        require(profit[msg.sender] != 0, "ShillNFT: There is no profit to be claimed.");
        uint256 _amount = profit[msg.sender];
        payable(msg.sender).transfer(_amount);
        profit[msg.sender].sub(_amount);
        emit claimSuccess(
            msg.sender,
            _amount
        );
    }
     /**
     * @dev Safely transfers `tokenId` token from `from` to `to`, checking first that contract recipients
     * are aware of the ERC721 protocol to prevent tokens from being forever locked.
     *
     * `_data` is additional data, it has no specified format and it is sent in call to `to`.
     *
     * This internal function is equivalent to {safeTransferFrom}, and can be used to e.g.
     * implement alternative mechanisms to perform token transfer, such as signature-based.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function _safeTransfer(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) internal virtual {
        _transfer(from, to, tokenId);
        require(_checkOnERC721Received(from, to, tokenId, _data), "ShillNFT: transfer to non ERC721Receiver implementer");
    }

    /**
     * @dev Returns whether `spender` is allowed to manage `tokenId`.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view virtual returns (bool) {
        require(_exists(tokenId), "ShillNFT: operator query for nonexistent token");
        address owner = ownerOf(tokenId);
        return (spender == owner || getApproved(tokenId) == spender || isApprovedForAll(owner, spender));
    }

    /**
     * @dev Safely mints `tokenId` and transfers it to `to`.
     *
     * Requirements:
     *
     * - `tokenId` must not exist.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function _safeMint(address to, uint256 tokenId) internal virtual {
        _safeMint(to, tokenId, "");
    }

    /**
     * @dev Same as {xref-ERC721-_safeMint-address-uint256-}[`_safeMint`], with an additional `data` parameter which is
     * forwarded in {IERC721Receiver-onERC721Received} to contract recipients.
     */
    function _safeMint(
        address to,
        uint256 tokenId,
        bytes memory _data
    ) internal virtual {
        _mint(to, tokenId);
        require(
            _checkOnERC721Received(address(0), to, tokenId, _data),
            "ShillNFT: transfer to non ERC721Receiver implementer"
        );
    }

    /**
     * @dev Mints `tokenId` and transfers it to `to`.
     *
     * WARNING: Usage of this method is discouraged, use {_safeMint} whenever possible
     *
     * Requirements:
     *
     * - `tokenId` must not exist.
     * - `to` cannot be the zero address.
     *
     * Emits a {Transfer} event.
     */
    function _mint(address to, uint256 tokenId) internal virtual {
        require(to != address(0), "ShillNFT: mint to the zero address");
        require(!_exists(tokenId), "ShillNFT: token already minted");

        _balances[to] += 1;
        _owners[tokenId] = to;

        emit Transfer(address(0), to, tokenId);
    }


    /**
     * @dev Approve `to` to operate on `tokenId`
     *
     * Emits a {Approval} event.
     */
    function _approve(address to, uint256 tokenId) internal virtual {
        _tokenApprovals[tokenId] = to;
        emit Approval(ownerOf(tokenId), to, tokenId);
    }

    /**
     * @dev Internal function to invoke {IERC721Receiver-onERC721Received} on a target address.
     * The call is not executed if the target address is not a contract.
     *
     * @param from address representing the previous owner of the given token ID
     * @param to target address that will receive the tokens
     * @param tokenId uint256 ID of the token to be transferred
     * @param _data bytes optional data to send along with the call
     * @return bool whether the call correctly returned the expected magic value
     */
    function _checkOnERC721Received(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) private returns (bool) {
        if (to.isContract()) {
            try IERC721Receiver(to).onERC721Received(_msgSender(), from, tokenId, _data) returns (bytes4 retval) {
                return retval == IERC721Receiver.onERC721Received.selector;
            } catch (bytes memory reason) {
                if (reason.length == 0) {
                    revert("ShillNFT: transfer to non ERC721Receiver implementer");
                } else {
                    assembly {
                        revert(add(32, reason), mload(reason))
                    }
                }
            }
        } else {
            return true;
        }
    } 
    /**
     * @dev Returns whether `tokenId` exists.
     *
     * Tokens can be managed by their owner or approved accounts via {approve} or {setApprovalForAll}.
     *
     * Tokens start existing when they are minted (`_mint`),
     * and stop existing when they are burned (`_burn`).
     */

    function calculateFee(uint256 _amount, uint8 _fee_percent) internal pure returns (uint256) {
        return _amount.mul(_fee_percent).div(
            10**2
        );
    }


    function getNftIdByEditionIdAndIssueId(uint128 _issue_id, uint128 _edition_id) internal pure returns (uint256) {
        return (uint256(_issue_id)<<128)|uint256(_edition_id);
    }

    function _exists(uint256 tokenId) internal view returns (bool) {
        return _owners[tokenId] != address(0);
    }
    function isIssueExist(uint128 _issue_id) public view returns (bool) {
        return (issues_by_id[_issue_id].issue_id != 0);
    }
    function isEditionExist(uint256 _NFT_id) public view returns (bool) {
        return (editions_by_id[_NFT_id].NFT_id != 0);
    }

    function getIssueIdByNFTId(uint256 _NFT_id) public pure returns (uint128) {
        return uint128(_NFT_id >> 128);
    }

    function getIssueNameByIssueId(uint128 _issue_id) public view returns (string memory) {
        require(isIssueExist(_issue_id), "ShillNFT: This issue is not exist.");
        return issues_by_id[_issue_id].name;
    }
    function getRoyaltyFeeByIssueId(uint128 _issue_id) public view returns (uint8) {
        require(isIssueExist(_issue_id), "ShillNFT: This issue is not exist.");
        return issues_by_id[_issue_id].royalty_fee;
    }
    function getLossRatioByIssueId(uint128 _issue_id) public view returns (uint8) {
        require(isIssueExist(_issue_id), "ShillNFT: This issue is not exist.");
        return issues_by_id[_issue_id].loss_ratio;
    }
    function getTotalAmountByIssueId(uint128 _issue_id) public view returns (uint128) {
        require(isIssueExist(_issue_id), "ShillNFT: This issue is not exist.");
        return issues_by_id[_issue_id].total_amount;
    }
    function getTransferPriceByNFTId(uint256 _NFT_id) public view returns (uint256) {
        require(isEditionExist(_NFT_id), "ShillNFT: Edition is not exist.");
        return editions_by_id[_NFT_id].transfer_price;
    }
    function getShillPriceByNFTId(uint256 _NFT_id) public view returns (uint256) {
        require(isEditionExist(_NFT_id), "ShillNFT: Edition is not exist.");
        return editions_by_id[_NFT_id].shillPrice;
    }
    function getRemainShillTimesByNFTId(uint256 _NFT_id) public view returns (uint64) {
        require(isEditionExist(_NFT_id), "ShillNFT: Edition is not exist.");
        return editions_by_id[_NFT_id].remain_shill_times;
    }
    function isNFTOnSale(uint256 _NFT_id) public view returns (bool) {
        require(isEditionExist(_NFT_id), "ShillNFT: Edition is not exist.");
        return editions_by_id[_NFT_id].is_on_sale;
    }

}