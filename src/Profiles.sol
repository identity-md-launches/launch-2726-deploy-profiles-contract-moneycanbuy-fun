// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDelegateRegistry} from "./interfaces/IDelegateRegistry.sol";

/// @dev The subset of the deployed TextRules helper read here (STATICCALL: the function is `pure`).
interface ITextRulesUrl {
    function checkScreenshotUrl(string calldata url) external pure;
}

/// @title Profiles
/// @notice A display name and a picture per wallet, standalone: no core contract reads it and it reads no core
///         contract. It holds no money (no `payable`, no `receive`, no token transfer), has no owner, no role and no
///         upgrade. One record per address, replaced whole by `set` and erased by `clear`.
///         Name: 3..20 bytes of `A-Z a-z 0-9 _`, not starting with `0x` / `0X`. Names are unique by skeleton (lower
///         case, `_` dropped, `0` -> `o`, `1` -> `l`, `i` -> `l`), at least 3 skeleton characters; a fixed list of
///         skeletons is reserved for nobody. Picture: none, an ERC-721 or ERC-1155 token the wallet holds when it
///         sets it (or, for ERC-721, holds through a delegate.xyz v2 delegation), or an https link on the host
///         allowlist of TextRules (`checkScreenshotUrl`). Token ownership is checked again on every read (`owned`);
///         every call to the token contract is capped at CALL_GAS and reads 32 bytes, so a token contract that
///         reverts, burns gas or returns a large payload only makes its own `owned` false.
contract Profiles {
    uint8 public constant PIC_NONE = 0;
    uint8 public constant PIC_ERC721 = 1;
    uint8 public constant PIC_ERC1155 = 2;
    uint8 public constant PIC_LINK = 3;

    /// @notice Gas cap of every call to a token contract or the delegate registry.
    uint256 public constant CALL_GAS = 30_000;

    address public immutable textRules;
    /// @notice delegate.xyz v2; address(0) disables delegated ERC-721 pictures.
    address public immutable delegateRegistry;

    struct Profile {
        bytes20 name; // ASCII, zero padded
        uint8 pic;
        uint64 since; // first `set` after an empty record
        address nft;
        uint256 tokenId;
        string link;
    }

    struct ProfileView {
        string name;
        uint8 pic;
        address nft;
        uint256 tokenId;
        string link;
        bool owned; // ERC-721/1155: held now (or delegated); link: true; none: false
        uint64 since;
    }

    mapping(address => Profile) private _profiles;
    /// @notice skeleton of a name => the wallet holding it
    mapping(bytes20 => address) public nameOwner;

    event ProfileSet(address indexed user, string name, uint8 pic, address nft, uint256 tokenId, string link);
    event ProfileCleared(address indexed user);

    error BadName();
    error NameTaken();
    error NameReserved();
    error BadPicture();
    error NotNftOwner();
    error ZeroAddress();
    /// @dev Raised by TextRules.checkScreenshotUrl and passed through unchanged (same selectors as VaultTypes).
    error HostNotAllowed();
    error BadEvidence();

    constructor(address textRules_, address delegateRegistry_) {
        if (textRules_ == address(0)) revert ZeroAddress();
        textRules = textRules_;
        delegateRegistry = delegateRegistry_;
    }

    // ------------------------------------------------------------------ write

    /// @notice Replaces the caller's whole profile. `name` may be empty (picture only), `pic` may be PIC_NONE
    ///         (name only); both empty reverts (`clear` erases). PIC_ERC721 / PIC_ERC1155: `nft` must report that
    ///         standard through ERC-165 and the caller must hold `tokenId` now; `link` empty. PIC_LINK: `nft` and
    ///         `tokenId` zero, `link` an allowlisted https link (TextRules). PIC_NONE: `nft`, `tokenId`, `link` empty.
    function set(string calldata name, uint8 pic, address nft, uint256 tokenId, string calldata link) external {
        bytes20 newName;
        bytes20 newKey;
        if (bytes(name).length != 0) {
            bool ok;
            (ok, newName, newKey) = _parse(name);
            if (!ok) revert BadName();
            if (_reserved(newKey)) revert NameReserved();
            address holder = nameOwner[newKey];
            if (holder != address(0) && holder != msg.sender) revert NameTaken();
        } else if (pic == PIC_NONE) {
            revert BadName();
        }
        _checkPicture(pic, nft, tokenId, link);

        Profile storage p = _profiles[msg.sender];
        bytes20 oldName = p.name;
        bytes20 oldKey = oldName == bytes20(0) ? bytes20(0) : _skeleton(oldName);
        if (oldKey != newKey) {
            if (oldKey != bytes20(0)) delete nameOwner[oldKey];
            if (newKey != bytes20(0)) nameOwner[newKey] = msg.sender;
        }

        uint64 since = p.since;
        if (since == 0) since = uint64(block.timestamp);
        p.name = newName;
        p.pic = pic;
        p.since = since;
        p.nft = nft;
        p.tokenId = tokenId;
        if (pic == PIC_LINK) p.link = link;
        else if (bytes(p.link).length != 0) delete p.link;

        emit ProfileSet(msg.sender, name, pic, nft, tokenId, link);
    }

    /// @notice Erases the caller's profile and frees its name at once.
    function clear() external {
        Profile storage p = _profiles[msg.sender];
        bytes20 oldName = p.name;
        if (oldName != bytes20(0)) delete nameOwner[_skeleton(oldName)];
        delete _profiles[msg.sender];
        emit ProfileCleared(msg.sender);
    }

    // ------------------------------------------------------------------ read

    function profileOf(address user) public view returns (ProfileView memory v) {
        Profile storage p = _profiles[user];
        v.name = _toString(p.name);
        v.pic = p.pic;
        v.since = p.since;
        if (v.pic == PIC_ERC721 || v.pic == PIC_ERC1155) {
            v.nft = p.nft;
            v.tokenId = p.tokenId;
            v.owned = _owned(user, v.pic, v.nft, v.tokenId);
        } else if (v.pic == PIC_LINK) {
            v.link = p.link;
            v.owned = true;
        }
    }

    function profilesOf(address[] calldata users) external view returns (ProfileView[] memory out) {
        uint256 n = users.length;
        out = new ProfileView[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = profileOf(users[i]);
        }
    }

    /// @notice The wallet holding `name` (by skeleton), address(0) if free or not a valid name.
    function ownerOfName(string calldata name) external view returns (address) {
        (bool ok,, bytes20 key) = _parse(name);
        return ok ? nameOwner[key] : address(0);
    }

    // ------------------------------------------------------------------ internal

    /// @dev Format check and skeleton of a name in one pass; ok = false on any rule broken.
    function _parse(string calldata s) private pure returns (bool ok, bytes20 name, bytes20 key) {
        bytes calldata b = bytes(s);
        uint256 len = b.length;
        if (len < 3 || len > 20) return (false, 0, 0);
        if (b[0] == "0" && (b[1] == "x" || b[1] == "X")) return (false, 0, 0);
        uint256 n;
        uint256 k;
        uint256 kl;
        for (uint256 i; i < len; ++i) {
            uint256 c = uint8(b[i]);
            uint256 lc;
            if (c >= 0x61 && c <= 0x7a) lc = c;
            else if (c >= 0x41 && c <= 0x5a) lc = c + 0x20;
            else if (c >= 0x30 && c <= 0x39) lc = c;
            else if (c != 0x5f) return (false, 0, 0);
            n |= c << (8 * (31 - i));
            if (lc != 0) {
                if (lc == 0x30) lc = 0x6f; // 0 -> o
                else if (lc == 0x31 || lc == 0x69) lc = 0x6c; // 1, i -> l
                k |= lc << (8 * (31 - kl));
                ++kl;
            }
        }
        if (kl < 3) return (false, 0, 0);
        return (true, bytes20(bytes32(n)), bytes20(bytes32(k)));
    }

    /// @dev Skeleton of a stored (already valid) name.
    function _skeleton(bytes20 name) private pure returns (bytes20) {
        uint256 k;
        uint256 kl;
        for (uint256 i; i < 20; ++i) {
            uint256 c = uint8(name[i]);
            if (c == 0) break;
            if (c == 0x5f) continue;
            if (c >= 0x41 && c <= 0x5a) c += 0x20;
            if (c == 0x30) c = 0x6f;
            else if (c == 0x31 || c == 0x69) c = 0x6c;
            k |= c << (8 * (31 - kl));
            ++kl;
        }
        return bytes20(bytes32(k));
    }

    /// @dev Reserved skeletons (the skeleton form of: moneycanbuy, moneycanbuyfun, mcb, imd, imdfun, swarm, yolo,
    ///      admin, official, support, team, treasury, oracle, mod, moderator, system, deployer).
    function _reserved(bytes20 k) private pure returns (bool) {
        return k == bytes20("moneycanbuy") || k == bytes20("moneycanbuyfun") || k == bytes20("mcb")
            || k == bytes20("lmd") || k == bytes20("lmdfun") || k == bytes20("swarm") || k == bytes20("yolo")
            || k == bytes20("admln") || k == bytes20("offlclal") || k == bytes20("support") || k == bytes20("team")
            || k == bytes20("treasury") || k == bytes20("oracle") || k == bytes20("mod") || k == bytes20("moderator")
            || k == bytes20("system") || k == bytes20("deployer");
    }

    function _checkPicture(uint8 pic, address nft, uint256 tokenId, string calldata link) private view {
        if (pic == PIC_NONE) {
            if (nft != address(0) || tokenId != 0 || bytes(link).length != 0) revert BadPicture();
        } else if (pic == PIC_ERC721 || pic == PIC_ERC1155) {
            if (bytes(link).length != 0 || nft.code.length == 0) revert BadPicture();
            bytes4 iface = pic == PIC_ERC721 ? bytes4(0x80ac58cd) : bytes4(0xd9b67a26);
            (bool ok, uint256 yes) = _call32(nft, abi.encodeWithSelector(0x01ffc9a7, iface));
            if (!ok || yes != 1) revert BadPicture();
            if (!_owned(msg.sender, pic, nft, tokenId)) revert NotNftOwner();
        } else if (pic == PIC_LINK) {
            if (nft != address(0) || tokenId != 0 || bytes(link).length == 0) revert BadPicture();
            ITextRulesUrl(textRules).checkScreenshotUrl(link);
        } else {
            revert BadPicture();
        }
    }

    /// @dev ERC-721: `ownerOf(id) == user`, or the owner delegated to `user` on delegate.xyz v2 (wallet, contract or
    ///      token level, all rights). ERC-1155: `balanceOf(user, id) > 0`. Any failure counts as not owned.
    function _owned(address user, uint8 pic, address nft, uint256 tokenId) private view returns (bool) {
        if (pic == PIC_ERC721) {
            (bool ok, uint256 w) = _call32(nft, abi.encodeWithSelector(0x6352211e, tokenId));
            if (!ok || w >> 160 != 0) return false;
            address holder = address(uint160(w));
            if (holder == user) return true;
            if (holder == address(0) || delegateRegistry == address(0)) return false;
            (ok, w) = _call32(
                delegateRegistry,
                abi.encodeWithSelector(
                    IDelegateRegistry.checkDelegateForERC721.selector, user, holder, nft, tokenId, bytes32(0)
                )
            );
            return ok && w == 1;
        }
        (bool ok1155, uint256 bal) = _call32(nft, abi.encodeWithSelector(0x00fdd58e, user, tokenId));
        return ok1155 && bal != 0;
    }

    /// @dev STATICCALL capped at CALL_GAS that copies at most 32 bytes back; ok only with >= 32 bytes returned.
    function _call32(address target, bytes memory data) private view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            ok := staticcall(CALL_GAS, target, add(data, 32), mload(data), 0, 32)
            if lt(returndatasize(), 32) { ok := 0 }
            word := mload(0)
        }
    }

    function _toString(bytes20 name) private pure returns (string memory s) {
        uint256 len;
        while (len < 20 && name[len] != 0) ++len;
        bytes memory b = new bytes(len);
        for (uint256 i; i < len; ++i) {
            b[i] = name[i];
        }
        s = string(b);
    }
}
