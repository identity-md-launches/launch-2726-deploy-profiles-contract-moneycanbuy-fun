// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockNFT} from "./MockNFT.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

contract ProfilesBurnableNFT is MockNFT {
    function burn(uint256 id) external {
        _burn(id);
    }
}

contract ProfilesMultiToken is ERC1155("") {
    function mint(address user, uint256 id, uint256 amount) external {
        _mint(user, id, amount, "");
    }

    function burn(address user, uint256 id, uint256 amount) external {
        _burn(user, id, amount);
    }
}

/// @dev A bounded response fixture: lengths near one ABI word, arbitrary first word, and revert data.
contract ProfilesReturnData {
    struct Reply {
        uint256 word;
        uint16 length;
        bool reverts;
    }

    mapping(bytes4 => Reply) private replies;

    function configure(bytes4 selector, uint256 word, uint16 length, bool reverts) external {
        replies[selector] = Reply(word, length, reverts);
    }

    fallback() external {
        Reply memory reply = replies[msg.sig];
        uint256 word = reply.word;
        uint256 length = reply.length;
        bool reverts = reply.reverts;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, word)
            if reverts { revert(ptr, length) }
            return(ptr, length)
        }
    }
}
