  -----------------------------------------------------
  Illyrian Token (BEP20)
  Official Contract Source - Verified on BscScan
  -----------------------------------------------------
  Website:  https://www.illyriantoken.com
  GitHub:   https://github.com/illyrianfoundation/Illyrian-Token
  Whitepaper: https://illyrian-token-foundation.gitbook.io/illyrian-token-whitepaper/
  -----------------------------------------------------

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
}

contract Illyrian {
    // --- ERC20 metadata ---
    string public constant name = "Illyrian Token";
    string public constant symbol = "ILLYRIAN";
    uint8  public constant decimals = 18;

    // --- ownership ---
    address public owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    // --- supply / balances ---
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    // --- transfer controls ---
    bool public paused;                               // global pause
    bool public publicTransfersOpen;                  // default: false
    mapping(address => bool) public frozen;           // per-address freeze
    mapping(address => bool) public transferUnlocked; // per-address send permission

    // --- optional receive whitelist ---
    bool public enforceReceiveWhitelist;              // default: false
    mapping(address => bool) public receiveWhitelisted;

    // --- optional admin move ---
    bool public adminMoveFeaturePermanentlyDisabled;
    bool public adminMoveEnabled;

    // --- allowances / approvals ---
    mapping(address => mapping(address => uint256)) private _allowances;
    bool public dexApprovalsOpen;                     // default: false

    // --- DEX / LP controls ---
    address public lpRouter;                          // router (e.g., Pancake V2)
    address public lpPair;                            // kept for back-compat/convenience
    bool    public lpWindowOpen;                      // router can pull from owner while true
    bool    public lpWindowPermanentlyClosed;         // one-way fuse
    bool    public dexSwapsAllowed;                   // default: false (block swaps via AMM pairs)

    // --- multi-pair guard ---
    mapping(address => bool) public isAmmPair;
    event AmmPairSet(address indexed pair, bool ok);

    // --- events ---
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed tokenOwner, address indexed spender, uint256 value);
    event Paused();
    event Unpaused();
    event Frozen(address indexed wallet);
    event Unfrozen(address indexed wallet);
    event TransferUnlocked(address indexed wallet);
    event TransferLocked(address indexed wallet);
    event AdminMove(address indexed from, address indexed to, uint256 value);
    event AdminMoveEnabled();
    event AdminMoveDisabledForever();
    event ReceiveWhitelistSet(address indexed wallet, bool indexed ok);
    event PurchaseRecorded(address indexed buyer, uint256 amount, bytes32 indexed invoiceId);

    constructor() {
        owner = msg.sender;
        uint256 initial = 100_000_000_000 * (10 ** uint256(decimals)); // 100B
        totalSupply = initial;
        balanceOf[msg.sender] = initial;
        emit Transfer(address(0), msg.sender, initial);
    }

    // --- ERC20: transfer ---
    function transfer(address to, uint256 value) public returns (bool) {
        _enforceTransferRules(msg.sender, to, value);
        unchecked {
            balanceOf[msg.sender] -= value;
            balanceOf[to] += value;
        }
        emit Transfer(msg.sender, to, value);
        return true;
    }

    // --- batch transfer (owner only) ---
    function batchTransfer(address[] calldata recipients, uint256[] calldata amounts)
        external onlyOwner returns (bool)
    {
        require(recipients.length == amounts.length, "len mismatch");
        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) total += amounts[i];
        require(balanceOf[msg.sender] >= total, "insufficient");

        unchecked {
            balanceOf[msg.sender] -= total;
            for (uint256 i = 0; i < recipients.length; i++) {
                address to = recipients[i];
                uint256 amt = amounts[i];
                require(to != address(0), "zero addr");
                require(!frozen[to], "to frozen");
                if (enforceReceiveWhitelist && !(dexApprovalsOpen && publicTransfersOpen)) {
                    require(receiveWhitelisted[to], "receiver not whitelisted");
                }
                balanceOf[to] += amt;
                emit Transfer(msg.sender, to, amt);
            }
        }
        return true;
    }

    // --- admin move (optional) ---
    function adminMove(address from, address to, uint256 amount)
        external onlyOwner returns (bool)
    {
        require(adminMoveEnabled, "adminMove disabled");
        require(from != address(0) && to != address(0), "zero addr");
        require(!frozen[from] && !frozen[to], "frozen");
        require(balanceOf[from] >= amount, "insufficient");
        if (enforceReceiveWhitelist && !(dexApprovalsOpen && publicTransfersOpen)) {
            require(receiveWhitelisted[to], "receiver not whitelisted");
        }
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        emit AdminMove(from, to, amount);
        emit Transfer(from, to, amount);
        return true;
    }

    function enableAdminMove() external onlyOwner {
        require(!adminMoveFeaturePermanentlyDisabled, "permanently disabled");
        adminMoveEnabled = true;
        emit AdminMoveEnabled();
    }

    function permanentlyDisableAdminMove() external onlyOwner {
        adminMoveEnabled = false;
        adminMoveFeaturePermanentlyDisabled = true;
        emit AdminMoveDisabledForever();
    }

    // --- global transfer switch ---
    function openPublicTransfers() external onlyOwner { publicTransfersOpen = true; }
    function closePublicTransfers() external onlyOwner { publicTransfersOpen = false; }

    // --- receive whitelist ---
    function setEnforceReceiveWhitelist(bool on) external onlyOwner { enforceReceiveWhitelist = on; }
    function setReceiveWhitelisted(address wallet, bool ok) external onlyOwner {
        receiveWhitelisted[wallet] = ok;
        emit ReceiveWhitelistSet(wallet, ok);
    }
    function batchSetReceiveWhitelisted(address[] calldata wallets, bool[] calldata oks)
        external onlyOwner
    {
        require(wallets.length == oks.length, "len mismatch");
        for (uint256 i = 0; i < wallets.length; i++) {
            receiveWhitelisted[wallets[i]] = oks[i];
            emit ReceiveWhitelistSet(wallets[i], oks[i]);
        }
    }

    // --- approvals / allowances ---
    function openDexApprovals() external onlyOwner { dexApprovalsOpen = true; }
    function closeDexApprovals() external onlyOwner { dexApprovalsOpen = false; }

    // --- DEX swaps kill-switch ---
    function allowDexSwaps() external onlyOwner { dexSwapsAllowed = true; }
    function blockDexSwaps() external onlyOwner { dexSwapsAllowed = false; }

    // --- ERC20 views ---
    function allowance(address tokenOwner, address spender) external view returns (uint256) {
        return _allowances[tokenOwner][spender];
    }
    function canReceiveNow(address to) external view returns (bool) {
        if (paused || frozen[to]) return false;
        if (!enforceReceiveWhitelist) return true;
        if (!(dexApprovalsOpen && publicTransfersOpen)) return receiveWhitelisted[to];
        return true;
    }
    function canSendNow(address from) external view returns (bool) {
        if (paused || frozen[from]) return false;
        if (from == owner) return true;
        return (publicTransfersOpen || transferUnlocked[from]);
    }

    // --- ERC20: approve ---
    function approve(address spender, uint256 amount) external returns (bool) {
        require(dexApprovalsOpen, "approvals closed");
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    // --- ERC20: transferFrom ---
    // Mode A (dexApprovalsOpen): standard ERC20 path with rule checks.
    // Mode B (!dexApprovalsOpen): only lpRouter may pull from owner during lpWindowOpen.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (dexApprovalsOpen) {
            _enforceTransferRules(from, to, amount);
            uint256 allowed = _allowances[from][msg.sender];
            require(allowed >= amount, "allowance");
            unchecked {
                _allowances[from][msg.sender] = allowed - amount;
                balanceOf[from] -= amount;
                balanceOf[to] += amount;
            }
            emit Transfer(from, to, amount);
            return true;
        }

        require(lpWindowOpen, "transferFrom closed");
        require(msg.sender == lpRouter, "only router");
        require(from == owner, "from must be owner");
        _enforceTransferRules(from, to, amount);
        uint256 allowedOwner = _allowances[from][msg.sender];
        require(allowedOwner >= amount, "allowance");
        unchecked {
            _allowances[from][msg.sender] = allowedOwner - amount;
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
        return true;
    }

    // --- transfer gate (multi-pair) ---
    function _enforceTransferRules(address from, address to, uint256 value) internal view {
        require(!paused, "paused");
        require(to != address(0), "zero addr");
        require(value > 0, "zero");
        require(balanceOf[from] >= value, "insufficient");
        require(!frozen[from] && !frozen[to], "frozen");

        // Block transfers that touch any registered AMM pair unless:
        // - during LP window via lpRouter and one side is owner, or
        // - dexSwapsAllowed is true.
        bool touchesPair = isAmmPair[from] || isAmmPair[to];
        if (touchesPair) {
            bool lpException =
                lpWindowOpen &&
                (msg.sender == lpRouter) &&
                (from == owner || to == owner);
            require(lpException || dexSwapsAllowed, "DEX swaps disabled");
        }

        // Receive whitelist (if enabled) except when public DEX mode is open.
        if (enforceReceiveWhitelist && !(dexApprovalsOpen && publicTransfersOpen)) {
            bool lpWhitelistException = lpWindowOpen && (msg.sender == lpRouter) && (from == owner);
            if (!lpWhitelistException) {
                require(receiveWhitelisted[to], "receiver not whitelisted");
            }
        }

        // Non-owner cannot send unless unlocked or public transfers are open.
        if (from != owner) {
            require(publicTransfersOpen || transferUnlocked[from], "locked");
        }
    }

    // --- ops ---
    function pause() external onlyOwner { paused = true; emit Paused(); }
    function unpause() external onlyOwner { paused = false; emit Unpaused(); }

    function freeze(address wallet) external onlyOwner { frozen[wallet] = true; emit Frozen(wallet); }
    function unfreeze(address wallet) external onlyOwner { frozen[wallet] = false; emit Unfrozen(wallet); }

    function setTransferUnlocked(address wallet, bool unlocked) external onlyOwner {
        transferUnlocked[wallet] = unlocked;
        if (unlocked) emit TransferUnlocked(wallet);
        else emit TransferLocked(wallet);
    }

    // --- deliver + record (owner only) ---
    function deliverAndRecord(address to, uint256 amount, bytes32 invoiceId)
        external onlyOwner
    {
        if (enforceReceiveWhitelist && !(dexApprovalsOpen && publicTransfersOpen)) {
            require(receiveWhitelisted[to], "receiver not whitelisted");
        }
        require(!frozen[to], "to frozen");
        require(balanceOf[owner] >= amount, "insufficient");
        unchecked {
            balanceOf[owner] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(owner, to, amount);
        emit PurchaseRecorded(to, amount, invoiceId);
    }

    // --- burn (owner) ---
    function burn(uint256 amount) external onlyOwner {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        unchecked {
            balanceOf[msg.sender] -= amount;
            totalSupply -= amount;
        }
        emit Transfer(msg.sender, address(0), amount);
    }

    // --- ownership ---
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero addr");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // --- rescue ---
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        require(token != address(this), "self");
        IERC20(token).transfer(owner, amount);
    }
    function rescueBNB(uint256 amount) external onlyOwner {
        (bool ok, ) = payable(owner).call{value: amount}("");
        require(ok, "transfer failed");
    }
    receive() external payable {}

    // --- LP window ---
    function openLpWindow(address router) external onlyOwner {
        require(!lpWindowPermanentlyClosed, "liquidity path closed");
        require(router != address(0), "zero router");
        lpRouter = router;
        lpWindowOpen = true;
    }

    // Back-compat: also marks as AMM pair
    function setLpPair(address pair) external onlyOwner {
        lpPair = pair;
        isAmmPair[pair] = true;
        emit AmmPairSet(pair, true);
    }

    function setAmmPair(address pair, bool ok) external onlyOwner {
        require(pair != address(0), "zero pair");
        isAmmPair[pair] = ok;
        emit AmmPairSet(pair, ok);
    }

    function approveRouter(uint256 amount) external onlyOwner {
        require(lpWindowOpen, "liquidity path not active");
        _allowances[owner][lpRouter] = amount;
        emit Approval(owner, lpRouter, amount);
    }

    function permanentlyCloseLpWindow() external onlyOwner {
        _allowances[owner][lpRouter] = 0;
        lpWindowOpen = false;
        lpWindowPermanentlyClosed = true;
        emit Approval(owner, lpRouter, 0);
    }
}
