// SPDX-License-Identifier: MIT
// Cowri Labs Inc.

pragma solidity =0.8.10;

import "abdk-libraries-solidity/ABDKMath64x64.sol";
import {EvolvingProteus} from "../proteus/EvolvingProteus.sol";
import {SpecifiedToken} from "../proteus/ILiquidityPoolImplementation.sol";

/**
  The test helper contract used for calling some internal methods in the evolving proteus contract & viewing some curve equation parameters
*/
contract EvolvingInstrumentedProteus is EvolvingProteus {
    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for int256;

    constructor(
        int128 py_init,
        int128 px_init,
        int128 py_final,
        int128 px_final,
        uint256 curveEvolutionStartTime,
        uint256 curveEvolutionDuration
    ) EvolvingProteus(py_init, px_init, py_final, px_final, curveEvolutionStartTime, curveEvolutionDuration) {}

    function swap(
        bool roundDirection,
        int256 specifiedAmount,
        int256 xi,
        int256 yi,
        SpecifiedToken specifiedToken
    ) public view returns (int256 computedAmount) {
        computedAmount = _swap(
            roundDirection,
            specifiedAmount,
            xi,
            yi,
            specifiedToken
        );
    }

    function getSwapMax(
        int256 xi, 
        int256 yi, 
        bool token
    ) public view returns (uint256 maxInput) {
        int256 utility = _getUtility(xi, yi);
        int256 xf;
        int256 yf;

        if (token) {
            (xf, yf) = getPointGivenYandUtility(MIN_BALANCE, utility);
        }
        else {
            (xf, yf) = getPointGivenXandUtility(MIN_BALANCE, utility);
        }
        int256 _max = token ? xf - xi : yf - yi;

        if (_max <= 0) {
            revert CurveError(_max);
        }
        maxInput = uint256(_max) * 10;
    }

    function printConfig() view public returns (int128, int128, int128, int128) {
        return (py_init, px_init, py_final, px_final);
    }

    function reserveTokenSpecified(
        SpecifiedToken specifiedToken,
        int256 specifiedAmount,
        bool roundDirection,
        int256 si,
        int256 xi,
        int256 yi
    ) public view returns (int256 computedAmount) {
        computedAmount = _reserveTokenSpecified(
            specifiedToken,
            specifiedAmount,
            roundDirection,
            si,
            xi,
            yi
        );
    }

    function lpTokenSpecified(
        SpecifiedToken specifiedToken,
        int256 specifiedAmount,
        bool roundDirection,
        int256 si,
        int256 xi,
        int256 yi
    ) public view returns (int256 computedAmount) {
        computedAmount = _lpTokenSpecified(
            specifiedToken,
            specifiedAmount,
            roundDirection,
            si,
            xi,
            yi
        );
    }

    function getUtility(
        int256 x,
        int256 y
    ) public view returns (int256 utility) {
        utility = _getUtility(x, y);
    }

    function getPointGivenXandUtility(
        int256 x,
        int256 utility
    ) public view returns (int256 xf, int256 yf) {
        return _getPointGivenXandUtility(x, utility);
    }

    function getPointGivenYandUtility(
        int256 y,
        int256 utility
    ) public view returns (int256 xf, int256 yf) {
        return _getPointGivenYandUtility(y, utility);
    }

}