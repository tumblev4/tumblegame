// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Website: https://tumblegame.xyz/
// X:       https://x.com/tumblegamev4

import { ProtectedLaunchTokenV1 } from "./launch-protection/ProtectedLaunchTokenV1.sol";

/// @title TUMBLE
/// @notice Programmable's ProtectedLaunchTokenV1, unchanged, plus read-only project details for explorers and wallets:
///  the description(), website(), image(), extraData() and metadata() getters of Programmable's standard tokens.
/// @dev Adds no state, no owner and no code on the transfer path. Every value below is a constant fixed at deployment.
contract TumbleToken is ProtectedLaunchTokenV1 {
    string private constant DESCRIPTION =
        "TUMBLE is a marble race on Ethereum. Buy $TUMBLE for 0.01 ETH or more, join once, and your tumbler runs in a race every 15 minutes while you hold. The winner is drawn on chain from Ethereum's RANDAO and paid in ETH from a pot that 2% of every trade fills.";
    string private constant WEBSITE = "https://tumblegame.xyz/";
    string private constant IMAGE = "https://raw.githubusercontent.com/tumblev4/tumblegame/main/assets/token.png";
    /// @dev Extra links as JSON bytes, in the format of Programmable's standard tokens.
    bytes private constant EXTRA_DATA = '{"v":1,"x":"https://x.com/tumblegamev4"}';

    constructor(string memory name_, string memory symbol_, uint256 supply_, address initializer_, address manager_)
        ProtectedLaunchTokenV1(name_, symbol_, supply_, initializer_, manager_)
    {}

    function description() external pure returns (string memory) {
        return DESCRIPTION;
    }

    function website() external pure returns (string memory) {
        return WEBSITE;
    }

    function image() external pure returns (string memory) {
        return IMAGE;
    }

    function extraData() external pure returns (bytes memory) {
        return EXTRA_DATA;
    }

    /// @notice The project details in one call: description, website, image and extra links.
    function metadata() external pure returns (string memory, string memory, string memory, bytes memory) {
        return (DESCRIPTION, WEBSITE, IMAGE, EXTRA_DATA);
    }
}
