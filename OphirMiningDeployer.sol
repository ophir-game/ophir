// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {OphirMining} from "./OphirMining.sol";

/*
    OphirMiningDeployer — split-route deployment of OPHIR Mining.
    Mining records its creator as _deployer and only that account may call the
    one-time initialize(). Deployed bare through the CREATE2 proxy, the proxy
    would be _deployer and initialize() could never be called. This deployer
    creates Mining; initialize() is triggered afterwards through init(), which
    only the sdw wallet may call (the token/buildings addresses depend on the
    mining address, so they cannot be constructor arguments here).
*/
contract OphirMiningDeployer {
    address private constant SDW = 0xE9A232aEfaA230a38BC9Fec961eEA19134903308;

    OphirMining public immutable mining;

    error NotSdw();

    constructor(address miners_) {
        mining = new OphirMining(miners_);
    }

    /// @notice One-time forward of Mining.initialize(); only the sdw wallet may call.
    function init(address token_, address buildings_) external {
        if (msg.sender != SDW) revert NotSdw();
        mining.initialize(token_, buildings_);
    }
}
