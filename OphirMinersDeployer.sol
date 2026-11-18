// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {OphirMiners} from "./OphirMiners.sol";

/*
    OphirMinersDeployer — split-route deployment of OPHIR Miners.
    Miners sets its owner to msg.sender, so it cannot be deployed bare through the
    CREATE2 proxy (the proxy would own it forever). This deployer creates it, opens
    the mint, and starts the Ownable2Step ownership transfer to the sdw wallet
    (completed by sdw calling acceptOwnership(); the market escrow is set by sdw
    right after, since the market address depends on the miners address).
*/
contract OphirMinersDeployer {
    address private constant SDW = 0xE9A232aEfaA230a38BC9Fec961eEA19134903308;
    address private constant AGENT_ID_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    string private constant IMAGE_BASE = "https://ophirbnb.pages.dev/art/";

    address public immutable miners;

    constructor() {
        OphirMiners m = new OphirMiners(AGENT_ID_REGISTRY, SDW, SDW, IMAGE_BASE);
        m.setMintOpen(true);
        m.transferOwnership(SDW);
        miners = address(m);
    }
}
