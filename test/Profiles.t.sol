// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

import {Profiles} from "../src/Profiles.sol";
import {TextRules} from "../src/helpers/TextRules.sol";
import {MockNFT} from "./mocks/MockNFT.sol";
import {MockDelegateRegistry} from "./mocks/MockDelegateRegistry.sol";

contract MockMulti is ERC1155("") {
    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

/// @dev A token contract that claims both standards and misbehaves on demand in ownerOf / balanceOf.
contract EvilNft {
    uint8 public mode; // 0 honest, 1 revert, 2 burn all gas, 3 huge return, 4 short return, 5 dirty address
    address public holder;

    function setMode(uint8 m) external {
        mode = m;
    }

    function setHolder(address h) external {
        holder = h;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function ownerOf(uint256) external view returns (address) {
        _misbehave();
        if (mode == 5) {
            uint256 dirty = uint256(uint160(holder)) | (uint256(1) << 200);
            assembly {
                mstore(0, dirty)
                return(0, 32)
            }
        }
        return holder;
    }

    function balanceOf(address user, uint256) external view returns (uint256) {
        _misbehave();
        return user == holder ? 1 : 0;
    }

    function _misbehave() private view {
        uint8 m = mode;
        if (m == 1) revert("nope");
        if (m == 2) {
            uint256 x;
            while (true) {
                x = uint256(keccak256(abi.encode(x)));
            }
        }
        if (m == 3) {
            assembly {
                return(0, 200000)
            }
        }
        if (m == 4) {
            assembly {
                mstore(0, 1)
                return(0, 16)
            }
        }
    }
}

/// @dev Name format, skeleton uniqueness, reserved names, rename / clear freeing the name, ERC-721 / ERC-1155 /
///      delegate.xyz pictures, ownership re-checked on read, misbehaving token contracts, profilesOf on 100 wallets,
///      link pictures through TextRules, events, no money.
contract ProfilesTest is Test {
    Profiles profiles;
    TextRules rules;
    MockNFT nft;
    MockMulti multi;
    MockDelegateRegistry registry;
    EvilNft evil;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);

    string constant ARWEAVE = "https://arweave.net/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ";

    event ProfileSet(address indexed user, string name, uint8 pic, address nft, uint256 tokenId, string link);
    event ProfileCleared(address indexed user);

    function setUp() public {
        rules = new TextRules();
        registry = new MockDelegateRegistry();
        profiles = new Profiles(address(rules), address(registry));
        nft = new MockNFT();
        multi = new MockMulti();
        evil = new EvilNft();
        nft.mint(ALICE, 827);
        multi.mint(ALICE, 5, 1);
    }

    function _name(address u, string memory n) internal {
        vm.prank(u);
        profiles.set(n, 0, address(0), 0, "");
    }

    function _expectName(address u, string memory n, bytes4 err) internal {
        vm.prank(u);
        vm.expectRevert(err);
        profiles.set(n, 0, address(0), 0, "");
    }

    // ------------------------------------------------------------------ name format

    function test_ValidNames() public {
        _name(ALICE, "alice");
        assertEq(profiles.profileOf(ALICE).name, "alice");
        _name(BOB, "Bob_42");
        _name(CAROL, "abcdefghijklmnopqrst"); // 20 bytes
        assertEq(profiles.profileOf(CAROL).name, "abcdefghijklmnopqrst");
        _name(address(0xD1), "xyz");
        _name(address(0xD2), "x0abc"); // 0x only forbidden at the start
        assertEq(profiles.ownerOfName("BOB_42"), BOB);
    }

    function test_Dots_BadName() public {
        _expectName(ALICE, "al.ice", Profiles.BadName.selector);
        _expectName(ALICE, "alice.eth", Profiles.BadName.selector);
        _expectName(ALICE, ".alice", Profiles.BadName.selector);
        _expectName(ALICE, "alice.", Profiles.BadName.selector);
    }

    function test_Space_BadName() public {
        _expectName(ALICE, "al ice", Profiles.BadName.selector);
        _expectName(ALICE, " alice", Profiles.BadName.selector);
        _expectName(ALICE, "alice ", Profiles.BadName.selector);
    }

    function test_Cyrillic_BadName() public {
        _expectName(ALICE, "\xd0\xb0lice", Profiles.BadName.selector); // Cyrillic a
        _expectName(ALICE, "\xd0\xb0\xd0\xbb\xd0\xb8\xd1\x81\xd0\xb0", Profiles.BadName.selector);
    }

    function test_Emoji_BadName() public {
        _expectName(ALICE, unicode"alice🐸", Profiles.BadName.selector);
        _expectName(ALICE, unicode"🐸🐸🐸", Profiles.BadName.selector);
    }

    function test_OtherBadNames() public {
        _expectName(ALICE, "ab", Profiles.BadName.selector); // 2 bytes
        _expectName(ALICE, "abcdefghijklmnopqrstu", Profiles.BadName.selector); // 21 bytes
        _expectName(ALICE, "0xa2b0", Profiles.BadName.selector);
        _expectName(ALICE, "0Xa2b0", Profiles.BadName.selector);
        _expectName(ALICE, "a__", Profiles.BadName.selector); // skeleton "a"
        _expectName(ALICE, "_a_b_", Profiles.BadName.selector); // skeleton "ab"
        _expectName(ALICE, "al-ice", Profiles.BadName.selector);
        _expectName(ALICE, "al@ice", Profiles.BadName.selector);
        _expectName(ALICE, "al/ice", Profiles.BadName.selector);
        _expectName(ALICE, "ali\x00e", Profiles.BadName.selector);
        // empty name without a picture = empty profile
        _expectName(ALICE, "", Profiles.BadName.selector);
        assertEq(profiles.ownerOfName("al.ice"), address(0));
    }

    // ------------------------------------------------------------------ skeleton

    function test_SkeletonUnique() public {
        _name(ALICE, "alice");
        string[7] memory same = ["ALICE", "Alice", "al_ice", "a1ice", "aIice", "AL1CE", "a_l_i_c_e"];
        for (uint256 i; i < same.length; ++i) {
            _expectName(BOB, same[i], Profiles.NameTaken.selector);
            assertEq(profiles.ownerOfName(same[i]), ALICE);
        }
        // 0 -> o
        _name(BOB, "b0b");
        _expectName(CAROL, "bob", Profiles.NameTaken.selector);
        _expectName(CAROL, "BOB", Profiles.NameTaken.selector);
        // the owner may change the case or underscores of its own name
        _name(ALICE, "A_L_I_C_E");
        assertEq(profiles.profileOf(ALICE).name, "A_L_I_C_E");
        assertEq(profiles.ownerOfName("alice"), ALICE);
    }

    function test_Reserved() public {
        string[17] memory words = [
            "moneycanbuy",
            "moneycanbuyfun",
            "mcb",
            "imd",
            "imdfun",
            "swarm",
            "yolo",
            "admin",
            "official",
            "support",
            "team",
            "treasury",
            "oracle",
            "mod",
            "moderator",
            "system",
            "deployer"
        ];
        for (uint256 i; i < words.length; ++i) {
            _expectName(ALICE, words[i], Profiles.NameReserved.selector);
        }
        string[9] memory variants =
            ["m0ney_canbuy", "MoneyCanBuy", "IMD", "1md", "Y0L0", "Adm1n", "0FFICIAL", "m_c_b", "Team_"];
        for (uint256 i; i < variants.length; ++i) {
            _expectName(ALICE, variants[i], Profiles.NameReserved.selector);
        }
        // not reserved: a longer name around a reserved word
        _name(ALICE, "yolo_fan");
        _name(BOB, "imd_holder");
    }

    // ------------------------------------------------------------------ rename, clear

    function test_RenameFreesOldName() public {
        _name(ALICE, "alice");
        _name(ALICE, "alice2");
        assertEq(profiles.ownerOfName("alice"), address(0));
        assertEq(profiles.ownerOfName("alice2"), ALICE);
        _name(BOB, "ALICE");
        assertEq(profiles.ownerOfName("alice"), BOB);
    }

    function test_ClearFreesName() public {
        _name(ALICE, "alice");
        uint64 since = profiles.profileOf(ALICE).since;
        assertEq(since, uint64(vm.getBlockTimestamp()));
        vm.expectEmit(true, false, false, false);
        emit ProfileCleared(ALICE);
        vm.prank(ALICE);
        profiles.clear();
        Profiles.ProfileView memory v = profiles.profileOf(ALICE);
        assertEq(v.name, "");
        assertEq(v.pic, 0);
        assertEq(v.since, 0);
        assertEq(profiles.ownerOfName("alice"), address(0));
        _name(BOB, "alice");
        assertEq(profiles.ownerOfName("alice"), BOB);
    }

    function test_PictureOnly_ThenNameFreed() public {
        _name(ALICE, "alice");
        vm.prank(ALICE);
        profiles.set("", 1, address(nft), 827, "");
        assertEq(profiles.ownerOfName("alice"), address(0));
        Profiles.ProfileView memory v = profiles.profileOf(ALICE);
        assertEq(v.name, "");
        assertTrue(v.owned);
    }

    function test_SinceKeptOnUpdate() public {
        _name(ALICE, "alice");
        uint64 t0 = profiles.profileOf(ALICE).since;
        assertGt(t0, 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _name(ALICE, "alice_b");
        assertEq(profiles.profileOf(ALICE).since, t0);
    }

    // ------------------------------------------------------------------ ERC-721

    function test_Nft721_SetAndOwned() public {
        vm.expectEmit(true, false, false, true);
        emit ProfileSet(ALICE, "alice", 1, address(nft), 827, "");
        vm.prank(ALICE);
        profiles.set("alice", 1, address(nft), 827, "");
        Profiles.ProfileView memory v = profiles.profileOf(ALICE);
        assertEq(v.pic, 1);
        assertEq(v.nft, address(nft));
        assertEq(v.tokenId, 827);
        assertTrue(v.owned);
    }

    function test_Nft721_NotOwner() public {
        vm.prank(BOB);
        vm.expectRevert(Profiles.NotNftOwner.selector);
        profiles.set("bob", 1, address(nft), 827, "");
        vm.prank(BOB);
        vm.expectRevert(Profiles.NotNftOwner.selector);
        profiles.set("bob", 1, address(nft), 999, ""); // not minted: ownerOf reverts
    }

    function test_Nft721_SoldThenOwnedFalse_NewOwnerSetsIt() public {
        vm.prank(ALICE);
        profiles.set("alice", 1, address(nft), 827, "");
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, 827);
        Profiles.ProfileView memory v = profiles.profileOf(ALICE);
        assertFalse(v.owned);
        assertEq(v.name, "alice");
        vm.prank(BOB);
        profiles.set("bob", 1, address(nft), 827, "");
        assertTrue(profiles.profileOf(BOB).owned);
        assertFalse(profiles.profileOf(ALICE).owned);
    }

    function test_Nft721_Delegate() public {
        // Alice keeps #827 in a cold wallet and delegates it to her hot wallet CAROL
        vm.prank(CAROL);
        vm.expectRevert(Profiles.NotNftOwner.selector);
        profiles.set("carol", 1, address(nft), 827, "");
        vm.prank(ALICE);
        registry.delegateERC721(CAROL, address(nft), 827, true);
        vm.prank(CAROL);
        profiles.set("carol", 1, address(nft), 827, "");
        assertTrue(profiles.profileOf(CAROL).owned);
        // revoked -> no picture
        vm.prank(ALICE);
        registry.delegateERC721(CAROL, address(nft), 827, false);
        assertFalse(profiles.profileOf(CAROL).owned);
        // wallet-level delegation counts too
        vm.prank(ALICE);
        registry.delegateAll(CAROL, true);
        assertTrue(profiles.profileOf(CAROL).owned);
    }

    function test_Nft721_NoRegistry_NoDelegate() public {
        Profiles p2 = new Profiles(address(rules), address(0));
        vm.prank(ALICE);
        registry.delegateAll(CAROL, true);
        vm.prank(CAROL);
        vm.expectRevert(Profiles.NotNftOwner.selector);
        p2.set("carol", 1, address(nft), 827, "");
    }

    // ------------------------------------------------------------------ ERC-1155

    function test_Nft1155_SetOwnedAndSold() public {
        vm.prank(ALICE);
        profiles.set("alice", 2, address(multi), 5, "");
        assertTrue(profiles.profileOf(ALICE).owned);
        vm.prank(BOB);
        vm.expectRevert(Profiles.NotNftOwner.selector);
        profiles.set("bob", 2, address(multi), 5, "");
        vm.prank(ALICE);
        multi.safeTransferFrom(ALICE, BOB, 5, 1, "");
        assertFalse(profiles.profileOf(ALICE).owned);
        vm.prank(BOB);
        profiles.set("bob", 2, address(multi), 5, "");
        assertTrue(profiles.profileOf(BOB).owned);
    }

    // ------------------------------------------------------------------ bad pictures

    function test_BadPicture() public {
        vm.startPrank(ALICE);
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("alice", 1, address(multi), 5, ""); // 1155 claimed as 721
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("alice", 2, address(nft), 827, ""); // 721 claimed as 1155
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("alice", 1, address(0xE0A), 827, ""); // no code
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("alice", 1, address(rules), 827, ""); // no ERC-165
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("alice", 4, address(0), 0, "");
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("alice", 0, address(nft), 0, "");
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("alice", 0, address(0), 827, "");
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("alice", 0, address(0), 0, ARWEAVE);
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("alice", 3, address(nft), 0, ARWEAVE);
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("alice", 3, address(0), 0, ""); // link picture without a link
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("alice", 1, address(nft), 827, ARWEAVE);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ misbehaving token contracts

    /// @dev Alice's picture lives on a contract that turns hostile after `set`; Bob and Carol share the same batch.
    function test_EvilNft_ReadNeverBreaks() public {
        evil.setHolder(ALICE);
        vm.prank(ALICE);
        profiles.set("alice", 1, address(evil), 1, "");
        vm.prank(BOB);
        profiles.set("bob", 0, address(0), 0, "");
        vm.prank(ALICE);
        nft.transferFrom(ALICE, CAROL, 827);
        vm.prank(CAROL);
        profiles.set("carol", 1, address(nft), 827, "");

        address[] memory users = new address[](3);
        users[0] = ALICE;
        users[1] = BOB;
        users[2] = CAROL;
        assertTrue(profiles.profilesOf(users)[0].owned);
        for (uint8 m = 1; m <= 5; ++m) {
            evil.setMode(m);
            uint256 g = gasleft();
            Profiles.ProfileView[] memory v = profiles.profilesOf{gas: 1_000_000}(users);
            g -= gasleft();
            console.log("evil mode", m, "profilesOf(3) gas", g);
            assertFalse(v[0].owned, "evil owned");
            assertEq(v[0].name, "alice");
            assertEq(v[1].name, "bob");
            assertTrue(v[2].owned, "carol owned");
            assertLt(g, 200_000);
        }
    }

    function test_EvilNft1155_ReadNeverBreaks() public {
        evil.setHolder(ALICE);
        vm.prank(ALICE);
        profiles.set("alice", 2, address(evil), 7, "");
        assertTrue(profiles.profileOf(ALICE).owned);
        for (uint8 m = 1; m <= 4; ++m) {
            evil.setMode(m);
            assertFalse(profiles.profileOf{gas: 500_000}(ALICE).owned);
        }
    }

    function test_EvilNft_CannotSetWhileHostile() public {
        evil.setHolder(ALICE);
        evil.setMode(2);
        vm.prank(ALICE);
        vm.expectRevert(Profiles.NotNftOwner.selector);
        profiles.set{gas: 1_000_000}("alice", 1, address(evil), 1, "");
    }

    // ------------------------------------------------------------------ profilesOf on 100 wallets

    function test_ProfilesOf100() public {
        address[] memory users = new address[](100);
        for (uint256 i; i < 100; ++i) {
            address u = address(uint160(0x10000 + i));
            users[i] = u;
            nft.mint(u, 10_000 + i);
            vm.prank(u);
            profiles.set(string.concat("user_", vm.toString(i)), 1, address(nft), 10_000 + i, "");
        }
        uint256 g = gasleft();
        Profiles.ProfileView[] memory v = profiles.profilesOf(users);
        g -= gasleft();
        console.log("profilesOf(100 x name+NFT) gas", g);
        assertEq(v.length, 100);
        assertEq(v[42].name, "user_42");
        assertTrue(v[99].owned);
        assertLt(g, 3_000_000);
    }

    // ------------------------------------------------------------------ link pictures

    function test_Link_ArweaveOk() public {
        assertEq(bytes(ARWEAVE).length, 63);
        vm.prank(ALICE);
        profiles.set("link_user", 3, address(0), 0, ARWEAVE);
        Profiles.ProfileView memory v = profiles.profileOf(ALICE);
        assertEq(v.link, ARWEAVE);
        assertEq(v.pic, 3);
        assertTrue(v.owned);
        // switching back to a name-only profile drops the link
        _name(ALICE, "link_user");
        assertEq(profiles.profileOf(ALICE).link, "");
    }

    function test_Link_OtherAllowlistedHosts() public {
        vm.startPrank(ALICE);
        profiles.set("", 3, address(0), 0, "https://i.ibb.co/abc/x.png");
        profiles.set("", 3, address(0), 0, "https://i.imgur.com/abc.png");
        profiles.set("", 3, address(0), 0, "https://pbs.twimg.com/media/abc.jpg");
        vm.stopPrank();
    }

    function test_Link_EvilHost() public {
        vm.startPrank(ALICE);
        vm.expectRevert(Profiles.HostNotAllowed.selector);
        profiles.set("alice", 3, address(0), 0, "https://evil.com/x.png");
        vm.expectRevert(Profiles.HostNotAllowed.selector);
        profiles.set("alice", 3, address(0), 0, "http://arweave.net/x");
        vm.expectRevert(Profiles.HostNotAllowed.selector);
        profiles.set("alice", 3, address(0), 0, "https://arweave.net.evil.com/x");
        vm.expectRevert(Profiles.HostNotAllowed.selector);
        profiles.set("alice", 3, address(0), 0, "ipfs://bafy");
        vm.expectRevert(Profiles.HostNotAllowed.selector);
        profiles.set("alice", 3, address(0), 0, "javascript:alert(1)");
        vm.stopPrank();
    }

    function test_Link_TooLongOrBadChars() public {
        bytes memory longUrl = bytes(string.concat("https://arweave.net/", _repeat("a", 281))); // 301 bytes
        assertEq(longUrl.length, 301);
        vm.startPrank(ALICE);
        vm.expectRevert(Profiles.BadEvidence.selector);
        profiles.set("alice", 3, address(0), 0, string(longUrl));
        bytes memory ok300 = bytes(string.concat("https://arweave.net/", _repeat("a", 280)));
        profiles.set("alice", 3, address(0), 0, string(ok300));
        vm.expectRevert(Profiles.BadEvidence.selector);
        profiles.set("alice", 3, address(0), 0, "https://arweave.net/a\x22onerror=1");
        vm.expectRevert(Profiles.BadEvidence.selector);
        profiles.set("alice", 3, address(0), 0, "https://arweave.net/<svg>");
        vm.stopPrank();
    }

    function _repeat(string memory c, uint256 n) internal pure returns (string memory s) {
        bytes memory b = new bytes(n);
        bytes1 ch = bytes(c)[0];
        for (uint256 i; i < n; ++i) {
            b[i] = ch;
        }
        s = string(b);
    }

    // ------------------------------------------------------------------ no money, no owner

    function test_NoMoney() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(profiles).call{value: 1}("");
        assertFalse(ok);
        vm.prank(ALICE);
        (ok,) = address(profiles).call{value: 1}(
            abi.encodeCall(Profiles.set, ("alice", uint8(0), address(0), uint256(0), ""))
        );
        assertFalse(ok);
        assertEq(address(profiles).balance, 0);
    }

    function test_ConstructorZeroTextRules() public {
        vm.expectRevert(Profiles.ZeroAddress.selector);
        new Profiles(address(0), address(registry));
    }
}

/// @dev One transaction per row of the gas table (run with --isolate so each call is metered as its own tx).
contract ProfilesGasTest is Test {
    Profiles profiles;
    MockNFT nft;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    string constant ARWEAVE = "https://arweave.net/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ";

    function setUp() public {
        profiles = new Profiles(address(new TextRules()), address(new MockDelegateRegistry()));
        nft = new MockNFT();
        nft.mint(ALICE, 827);
        vm.prank(BOB);
        profiles.set("bob_old", 0, address(0), 0, "");
    }

    function test_Gas_NameOnlyFirst() public {
        vm.prank(ALICE);
        profiles.set("alice", 0, address(0), 0, "");
    }

    function test_Gas_NameNft() public {
        vm.prank(ALICE);
        profiles.set("alice", 1, address(nft), 827, "");
    }

    function test_Gas_NameLink() public {
        vm.prank(ALICE);
        profiles.set("link_user", 3, address(0), 0, ARWEAVE);
    }

    function test_Gas_Rename() public {
        vm.prank(BOB);
        profiles.set("bob_new", 0, address(0), 0, "");
    }

    function test_Gas_Clear() public {
        vm.prank(BOB);
        profiles.clear();
    }
}
