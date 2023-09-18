// SPDX-License-Identifier: MIT
// Cowri Labs Inc.

pragma solidity =0.8.10;

import "abdk-libraries-solidity/ABDKMath64x64.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {ILiquidityPoolImplementation, SpecifiedToken} from "./ILiquidityPoolImplementation.sol";

/**
     * @dev The contract is called with the following parameters:
     y_init: the initial price at the y axis
     x_init: the initial price at the x axis
     y_final: the final price at the y axis
     x_final: the final price at the x axis
     time: the total duration of the curve's evolution (e.g. the amount of time it should take to evolve from the initial to the final prices)
     
     Using these 5 inputs we can calculate the curve's parameters at every point in time. 
     
     The parameters "a" and "b" are calculated from the price. a = 1/sqrt(y_axis_price) and b = sqrt(x_axis_price). 
     We calculate a(t) and b(t) by taking the time-dependant linear interpolate between the initial and final values. 
     In other words, a(t) = (a_init * (1-t)) + (a_final * (t)) and b(t) = (b_init * (1-t)) + (b_final * (t)), where "t"
     is the percentage of time elapsed relative to the total specified duration. Since 
     a_init, a_final, b_init and b_final can be easily calculated from the input parameters (prices), this is a trivial
     calculation. a() and b() are then called whenever a and b are needed, and return the correct value for
     a or b and the time t. When the total duration is reached, t remains = 1 and the curve will remain in its final shape. 

     Note: To mitigate rounding errors, which if too large could result in liquidity provider losses, we enforce certain constraints on the algorithm.
           Min transaction amount: A transaction amount cannot be too small relative to the size of the reserves in the pool. A transaction amount either as an input into the pool or an output from the pool will result in a transaction failure
           Max transaction amount: a transaction amount cannot be too large relative to the size of the reserves in the pool. 
           Min reserve ratio: The ratio between the two reserves cannot fall below a certain ratio. Any transaction that would result in the pool going above or below this ratio will fail.
           Max reserve ratio: the ratio between the two reserves cannot go above a certain ratio. Any transaction that results in the reserves going beyond this ratio will fall.
*/
contract EvolvingProteus is ILiquidityPoolImplementation {
    using ABDKMath64x64 for uint256;
    using ABDKMath64x64 for int256;
    using ABDKMath64x64 for int128;

    int128 constant ABDK_ONE = int128(int256(1 << 64));

    /** 
     @notice 
     max threshold for amounts deposited, withdrawn & swapped
    */ 
    uint256 constant INT_MAX = uint256(type(int256).max);
    /** 
     @notice 
     When a token has 18 decimals, this is one microtoken
    */ 
    int256 constant MIN_BALANCE = 10**12;
    /** 
     @notice 
     The maximum slope (balance of y reserve) / (balance of x reserve)
     This limits the pool to having at most 10**8 y for each x.
    */ 
    int128 constant MAX_M = 0x5f5e1000000000000000000;
    /** 
     @notice 
     The minimum slope (balance of y reserve) / (balance of x reserve)
     This limits the pool to having at most 10**8 x for each y.
    */ 
    int128 constant MIN_M = 0x00000000000002af31dc461;

    /** 
     @notice 
     The maximum price value calculated with abdk library equivalent to 10^26(wei)
    */ 
    int256 constant MAX_PRICE_VALUE = 1844674407370955161600000000;

    /** 
     @notice 
     The minimum price value calculated with abdk library equivalent to 10^12(wei)
    */ 
    int256 constant MIN_PRICE_VALUE = 184467440737;

    /** 
     @notice 
     This limits the pool to inputting or outputting
    */
    uint256 constant MAX_BALANCE_AMOUNT_RATIO = 10**11;
    
    /** 
     @notice 
     Equivalent to roughly twenty-five basis points since fee is applied twice.
    */
    uint256 public constant BASE_FEE = 800;
    
    /** 
     @notice 
     When a token has 18 decimals, this is 1 nanotoken
    */ 
    uint256 constant FIXED_FEE = 10**9;
    
    /** 
      @notice 
      multiplier for math operations
    */ 
    int256 constant MULTIPLIER = 1e18;
    
    /** 
      @notice 
      max price ratio
    */ 
    uint256 constant MAX_PRICE_RATIO = 10**4; // to be comparable with the prices calculated through abdk math
    
    /** 
      @notice 
      flag to indicate increase of the pool's perceived input or output
    */ 
    bool constant FEE_UP = true;
    
    /** 
      @notice 
      flag to indicate decrease of the pool's perceived input or output
    */ 
    bool constant FEE_DOWN = false;

    /** 
     @notice 
     The initial price at the y axis
    */ 
    int128 immutable public py_init;

    /** 
     @notice 
     The initial price at the x axis
    */ 
    int128 immutable public px_init;

    /** 
     @notice 
     The final price at the y axis
    */ 
    int128 immutable public py_final;

    /** 
     @notice 
     The final price at the x axis
    */ 
    int128 immutable public px_final;

    /** 
     @notice 
     curve evolution start time
    */ 
    uint256 immutable public t_init;

    /** 
     @notice 
     curve evolution end time
    */ 
    uint256 immutable public t_final;

    /** 
     @notice 
     duration over which the curve will evolve
    */ 
    uint256 immutable public curveEvolutionDuration;


    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//
    error AmountError();
    error BalanceError(int256 x, int256 y);
    error BoundaryError(int256 x, int256 y);
    error CurveError(int256 errorValue); 
    error InvalidPrice();
    error MinimumAllowedPriceExceeded();
    error MaximumAllowedPriceExceeded();
    error MaximumAllowedPriceRatioExceeded();
    error PoolNotActiveYet();


    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /**
      @param _py_init The initial price at the y axis
      @param _px_init The initial price at the x axis
      @param _py_final The final price at the y axis
      @param _px_final The final price at the y axis
      @param _curveEvolutionStartTime curve evolution start time
      @param _curveEvolutionDuration duration for which the curve will evolve
    */
    constructor(
        int128 _py_init,
        int128 _px_init,
        int128 _py_final,
        int128 _px_final,
        uint256 _curveEvolutionStartTime,
        uint256 _curveEvolutionDuration
    ) { 
        if (_curveEvolutionStartTime == 0) revert();

        // price value checks
        if (_py_init >= MAX_PRICE_VALUE || _py_final >= MAX_PRICE_VALUE) revert MaximumAllowedPriceExceeded();
        if (_px_init <= MIN_PRICE_VALUE || _px_final <= MIN_PRICE_VALUE) revert MinimumAllowedPriceExceeded();

        // at all times x price should be less than y price
        if (_py_init <= _px_init) revert InvalidPrice();
        if (_py_final <= _px_final) revert InvalidPrice();

        // max. price ratio check
        if (_py_init.div(_py_init.sub(_px_init)) > ABDKMath64x64.divu(MAX_PRICE_RATIO, 1)) revert MaximumAllowedPriceRatioExceeded();
        if (_py_final.div(_py_final.sub(_px_final)) > ABDKMath64x64.divu(MAX_PRICE_RATIO, 1)) revert MaximumAllowedPriceRatioExceeded();

        py_init = _py_init;
        px_init = _px_init;
        py_final = _py_final;
        px_final = _px_final;
        t_init = _curveEvolutionStartTime;
        t_final = _curveEvolutionStartTime + _curveEvolutionDuration;
        curveEvolutionDuration = _curveEvolutionDuration;
    }

    /**
       @notice Returns all the pool configuration params in a tuple
    */
    function params() public view returns (int128,int128,int128,int128,uint256,uint256, uint256) {
        return (py_init, px_init, py_final, px_final, t_init, t_final, curveEvolutionDuration);
    }

    /**
       @notice Calculates the time that has passed since deployment
    */
    function elapsed() public view returns (uint256) {
        if (block.timestamp > t_init) return block.timestamp - t_init;
        else return 0;
    }

    /**
       @notice Calculates the time as a percent of total duration
    */
    function t() public view returns (int128) {
        if (elapsed() == 0) return 0;
        else return elapsed().divu(curveEvolutionDuration);
    }

    /**
       @notice The minimum price (at the x asymptote) at the current block
    */
    function p_min() public view returns (int128) {
        if (t() > ABDK_ONE) return px_final;
        else if (t() == 0) return px_init;
        else return px_init.mul(ABDK_ONE.sub(t())).add(px_final.mul(t()));
    }

    /**
       @notice The maximum price (at the y asymptote) at the current block
    */
    function p_max() public view returns (int128) {
        if (t() > ABDK_ONE) return py_final;
        else if (t() == 0) return py_init;
        else return py_init.mul(ABDK_ONE.sub(t())).add(py_final.mul(t()));
    }

    /**
       @notice Calculates the a variable in the curve eq which is basically a sq. root of the inverse of y instantaneous price
    */
    function a() public view returns (int128) {
        return (p_max().inv()).sqrt();
    }

    /**
       @notice Calculates the b variable in the curve eq which is basically a sq. root of the inverse of x instantaneous price
    */
    function b() public view returns (int128) {
        return p_min().sqrt();
    }


    /**
     * @dev Given an input amount of one reserve token, we compute the output
     *  amount of the other reserve token, keeping utility invariant.
     * @dev We use FEE_DOWN because we want to decrease the perceived
     *  input amount and decrease the observed output amount.
     */
    function swapGivenInputAmount(
        uint256 xBalance,
        uint256 yBalance,
        uint256 inputAmount,
        SpecifiedToken inputToken
    ) external view returns (uint256 outputAmount) {
        // pool operations paused until curve evolution starts
        if (elapsed() == 0) revert PoolNotActiveYet();

        // input amount validations against the current balance
        require(
            inputAmount < INT_MAX && xBalance < INT_MAX && yBalance < INT_MAX
        );

        _checkAmountWithBalance(
            (inputToken == SpecifiedToken.X) ? xBalance : yBalance,
            inputAmount
        );

        int256 result = _swap(
            FEE_DOWN,
            int256(inputAmount),
            int256(xBalance),
            int256(yBalance),
            inputToken
        );
        // amount cannot be less than 0
        require(result < 0);

        // output amount validations against the current balance
        outputAmount = uint256(-result);
        _checkAmountWithBalance(
            (inputToken == SpecifiedToken.X) ? yBalance : xBalance,
            outputAmount
        );
    }

    /**
     * @dev Given an output amount of a reserve token, we compute the input
     *  amount of the other reserve token, keeping utility invariant.
     * @dev We use FEE_UP because we want to increase the perceived output
     *  amount and increase the observed input amount.
     */
    function swapGivenOutputAmount(
        uint256 xBalance,
        uint256 yBalance,
        uint256 outputAmount,
        SpecifiedToken outputToken
    ) external view returns (uint256 inputAmount) {
        // pool operations paused until curve evolution starts
        if (elapsed() == 0) revert PoolNotActiveYet();

        // output amount validations against the current balance
        require(
            outputAmount < INT_MAX && xBalance < INT_MAX && yBalance < INT_MAX
        );
        _checkAmountWithBalance(
            outputToken == SpecifiedToken.X ? xBalance : yBalance,
            outputAmount
        );

        int256 result = _swap(
            FEE_UP,
            -int256(outputAmount),
            int256(xBalance),
            int256(yBalance),
            outputToken
        );

        // amount cannot be less than 0
        require(result > 0);
        inputAmount = uint256(result);

        // input amount validations against the current balance
        _checkAmountWithBalance(
            outputToken == SpecifiedToken.X ? yBalance : xBalance,
            inputAmount
        );
    }

    /**
     * @dev Given an input amount of a reserve token, we compute the output
     *  amount of LP tokens, scaling the total supply of the LP tokens with the
     *  utility of the pool.
     * @dev We use FEE_DOWN because we want to decrease the perceived amount
     *  deposited and decrease the amount of LP tokens minted.
     */
    function depositGivenInputAmount(
        uint256 xBalance,
        uint256 yBalance,
        uint256 totalSupply,
        uint256 depositedAmount,
        SpecifiedToken depositedToken
    ) external view returns (uint256 mintedAmount) {
        // pool operations paused until curve evolution starts
        if (elapsed() == 0) revert PoolNotActiveYet();

        // deposit amount validations against the current balance
        require(
            depositedAmount < INT_MAX &&
                xBalance < INT_MAX &&
                yBalance < INT_MAX &&
                totalSupply < INT_MAX
        );

        _checkAmountWithBalance(
            (depositedToken == SpecifiedToken.X) ? xBalance : yBalance,
            depositedAmount
        );

        int256 result = _reserveTokenSpecified(
            depositedToken,
            int256(depositedAmount),
            FEE_DOWN,
            int256(totalSupply),
            int256(xBalance),
            int256(yBalance)
        );

        // amount cannot be less than 0
        require(result > 0);
        mintedAmount = uint256(result);
    }

    /**
     * @dev Given an output amount of the LP token, we compute an amount of
     *  a reserve token that must be deposited to scale the utility of the pool
     *  in proportion to the change in total supply of the LP token.
     * @dev We use FEE_UP because we want to increase the perceived change in
     *  total supply and increase the observed amount deposited.
     */
    function depositGivenOutputAmount(
        uint256 xBalance,
        uint256 yBalance,
        uint256 totalSupply,
        uint256 mintedAmount,
        SpecifiedToken depositedToken
    ) external view returns (uint256 depositedAmount) {
        // pool operations paused until curve evolution starts
        if (elapsed() == 0) revert PoolNotActiveYet();

        // lp amount validations against the current balance
        require(
            mintedAmount < INT_MAX &&
                xBalance < INT_MAX &&
                yBalance < INT_MAX &&
                totalSupply < INT_MAX
        );

        int256 result = _lpTokenSpecified(
            depositedToken,
            int256(mintedAmount),
            FEE_UP,
            int256(totalSupply),
            int256(xBalance),
            int256(yBalance)
        );

        // amount cannot be less than 0
        require(result > 0);
        depositedAmount = uint256(result);
    }

    /**
     * @dev Given an output amount of a reserve token, we compute an amount of
     *  LP tokens that must be burned in order to decrease the total supply in
     *  proportion to the decrease in utility.
     * @dev We use FEE_UP because we want to increase the perceived amount
     *  withdrawn from the pool and increase the observed decrease in total
     *  supply.
     */
    function withdrawGivenOutputAmount(
        uint256 xBalance,
        uint256 yBalance,
        uint256 totalSupply,
        uint256 withdrawnAmount,
        SpecifiedToken withdrawnToken
    ) external view returns (uint256 burnedAmount) {
        // pool operations paused until curve evolution starts
        if (elapsed() == 0) revert PoolNotActiveYet();

        // withdraw amount validations against the current balance
        require(
            withdrawnAmount < INT_MAX &&
                xBalance < INT_MAX &&
                yBalance < INT_MAX &&
                totalSupply < INT_MAX
        );

        int256 result = _reserveTokenSpecified(
            withdrawnToken,
            -int256(withdrawnAmount),
            FEE_UP,
            int256(totalSupply),
            int256(xBalance),
            int256(yBalance)
        );

        // amount cannot be less than 0
        require(result < 0);
        burnedAmount = uint256(-result);
    }

    /**
     * @dev Given an input amount of the LP token, we compute an amount of
     *  a reserve token that must be output to decrease the pool's utility in
     *  proportion to the pool's decrease in total supply of the LP token.
     * @dev We use FEE_UP because we want to increase the perceived amount of
     *  reserve tokens leaving the pool and to increase the observed amount of
     *  LP tokens being burned.
     */
    function withdrawGivenInputAmount(
        uint256 xBalance,
        uint256 yBalance,
        uint256 totalSupply,
        uint256 burnedAmount,
        SpecifiedToken withdrawnToken
    ) external view returns (uint256 withdrawnAmount) {
        // pool operations paused until curve evolution starts
        if (elapsed() == 0) revert PoolNotActiveYet();

        // lp amount validations against the current balance
        require(
            burnedAmount < INT_MAX &&
                xBalance < INT_MAX &&
                yBalance < INT_MAX &&
                totalSupply < INT_MAX
        );

        int256 result = _lpTokenSpecified(
            withdrawnToken,
            -int256(burnedAmount),
            FEE_DOWN,
            int256(totalSupply),
            int256(xBalance),
            int256(yBalance)
        );

        // amount cannot be less than 0
        require(result < 0);
        withdrawnAmount = uint256(-result);
    }

    /**
     * @dev From a starting point (xi, yi), we can begin a swap in four ways:
     *  [+x, -x, +y, -y]. This function abstracts over those four ways using
     *  the specifiedToken parameter and the sign of the specifiedAmount
     *  integer.
     * @dev A starting coordinate can be combined with the specified amount
     *  to find a known final coordinate. A final coordinate and a final
     *  utility can be used to determine the final point.
     * @dev Using the final point and the initial point, we can find how much
     *  of the non-specified token must enter or leave the pool in order to
     *  keep utility invariant.
     * @dev see notes above _findFinalPoint for information on direction
     *  and other variables declared in this scope.
     */
    function _swap(
        bool feeDirection,
        int256 specifiedAmount,
        int256 xi,
        int256 yi,
        SpecifiedToken specifiedToken
    ) internal view returns (int256 computedAmount) {
        int256 roundedSpecifiedAmount;
        // calculating the amount considering the fee
        {
            roundedSpecifiedAmount = _applyFeeByRounding(
                specifiedAmount,
                feeDirection
            );
        }

        int256 xf;
        int256 yf;
        // calculate final price points after the swap
        {

            int256 utility = _getUtility(xi, yi);

            if (specifiedToken == SpecifiedToken.X) {
                int256 fixedPoint = xi + roundedSpecifiedAmount;
                (xf, yf) = _findFinalPoint(
                    fixedPoint,
                    utility,
                    _getPointGivenXandUtility
                );

                // balance checks with consideration the computed amount
                computedAmount = _applyFeeByRounding(yf - yi, feeDirection);
                _checkBalances(xi + specifiedAmount, yi + computedAmount);
            } else {
                int256 fixedPoint = yi + roundedSpecifiedAmount;
                (xf, yf) = _findFinalPoint(
                    fixedPoint,
                    utility,
                    _getPointGivenYandUtility
                );

                // balance checks with consideration the computed amount
                computedAmount = _applyFeeByRounding(xf - xi, feeDirection);
                _checkBalances(xi + computedAmount, yi + specifiedAmount);
            }
        }
    }

    /**
     * @dev When performing a deposit given an input amount or a withdraw
     *  given an output amount, we know the initial point and final point,
     *  which allows us to find the initial utility and final utility.
     * @dev With the initial utility and final utility, we need to change
     *  the total supply in proportion to the change in utility.
     */
    function _reserveTokenSpecified(
        SpecifiedToken specifiedToken,
        int256 specifiedAmount,
        bool feeDirection,
        int256 si,
        int256 xi,
        int256 yi
    ) internal view returns (int256 computedAmount) {
        int256 xf;
        int256 yf;
        int256 ui;
        int256 uf;
        {
            // calculating the final price points considering the fee
            if (specifiedToken == SpecifiedToken.X) {
                xf = xi + _applyFeeByRounding(specifiedAmount, feeDirection);
                yf = yi;
            } else {
                yf = yi + _applyFeeByRounding(specifiedAmount, feeDirection);
                xf = xi;
            }
        }

        ui = _getUtility(xi, yi);
        uf = _getUtility(xf, yf);

        uint256 result = Math.mulDiv(uint256(uf), uint256(si), uint256(ui));
        require(result < INT_MAX);   
        int256 sf = int256(result);
        require(sf >= MIN_BALANCE); 

        // apply fee to the computed amount
        computedAmount = _applyFeeByRounding(sf - si, feeDirection);
        
        // reserve balances check based on the specified amount
        if (specifiedToken == SpecifiedToken.X) {
            _checkBalances(xi + specifiedAmount, yf);
        } else {
            _checkBalances(xf, yi + specifiedAmount);
        }
    }

    /**
     * @dev When performing a deposit given an output amount or a withdraw
     *  given an input amount, we know the initial total supply and the final
     *  total supply.
     * @dev Given the change in total supply, we need to find how much of a
     *  reserve token we need to take in or give out in order to change the
     *  pool's utility in proportion to the pool's change in total supply.
     * @dev see notes above _findFinalPoint for information on direction
     *  and other variables declared in this scope.
     */
    function _lpTokenSpecified(
        SpecifiedToken specifiedToken,
        int256 specifiedAmount,
        bool feeDirection,
        int256 si,
        int256 xi,
        int256 yi
    ) internal view returns (int256 computedAmount) {
        // get final utility considering the fee
        int256 uf = _getUtilityFinalLp(
            si,
            si + _applyFeeByRounding(specifiedAmount, feeDirection),
            xi,
            yi
        );

        // get final price points
        int256 xf;
        int256 yf;
        if (specifiedToken == SpecifiedToken.X) {

            (xf, yf) = _findFinalPoint(
                yi,
                uf,
                _getPointGivenYandUtility
            );

            // balance checks with consideration the computed amount
            computedAmount = _applyFeeByRounding(xf - xi, feeDirection);
            _checkBalances(xi + computedAmount, yf);
        } else {
            (xf, yf) = _findFinalPoint(
                xi,
                uf,
                _getPointGivenXandUtility
            );

            // balance checks with consideration the computed amount
            computedAmount = _applyFeeByRounding(yf - yi, feeDirection);
            _checkBalances(xf, yi + computedAmount);
        }
    }

    /**
     * @dev Calculate utility when lp token amount is specified while depositing/withdrawing liquidity
    */
    function _getUtilityFinalLp(
        int256 si,
        int256 sf,
        int256 xi,
        int256 yi
    ) internal view returns (int256 uf) {
        require(sf >= MIN_BALANCE);
        int256 ui = _getUtility(xi, yi);
        uint256 result = Math.mulDiv(uint256(ui), uint256(sf), uint256(si));
        require(result < INT_MAX);
        uf = int256(result);
        return uf;
    }

    /**
     * @dev This function leverages several properties of proteus to find
     *  the final state of the balances after an action. These properties are:
     *   1. There is always a known coordinate. We always know at least one of
     *      xf or yf. In swaps we know the specified token (ti + amount == tf).
     *      In deposits or withdrawals, we know the non-specified token
     *      (ti == tf).
     *   2. There is always a known utility. During swaps utility is invariant
     *      (ui == uf).  During deposits or withdrawals, utility varies linearly
     *      with the known change in total supply of the LP token.
     * @param fixedCoordinate Known coordinate
     * @param utility Known utility
     * @param getPoint Function that uses the known coordinate and the known
     *  utility to compute the unknown coordinate. Returns a point (x, y).
*/
    function _findFinalPoint(
        int256 fixedCoordinate,
        int256 utility,
        function(int256, int256)
            view
            returns (int256, int256) getPoint
    ) internal view returns (int256 xf, int256 yf) {
        return getPoint(fixedCoordinate, utility);
    }

    /**
     * @dev Utility is the pool's internal measure of how much value it holds
     * @dev The pool values the x reserve and y reserve based on how much of
     *  one it holds compared to the other. The higher ratio of y to x, the
     *  less it values y compared to x.
     * @dev the equation for a curve:
     *  k(ab - 1)u**2 + (ay + bx)u + xy/k = 0
     * @dev isolate u in the equation using the quadratic formula above gives us two solutions. 
     *  We always want the larger solution
     */
    function _getUtility(
        int256 x,
        int256 y
    ) internal view returns (int256 utility) {

        int128 a = a(); //these are abdk numbers representing the a and b values
        int128 b = b(); 

        int128 two = ABDKMath64x64.divu(uint256(2 * MULTIPLIER), uint256(MULTIPLIER));
        int128 one = ABDKMath64x64.divu(uint256(MULTIPLIER), uint256(MULTIPLIER));

        int128 aQuad = (a.mul(b).sub(one));
        int256 bQuad = (a.muli(y) + b.muli(x));
        int256 cQuad = x * y;

        int256 disc = int256(Math.sqrt(uint256((bQuad**2 - (aQuad.muli(cQuad)*4)))));

        int256 denQuad = aQuad.mul(two).muli(MULTIPLIER);
        int256 num1 = -bQuad*MULTIPLIER;
        int256 num2 = disc*MULTIPLIER;

        int256 r0 = (num1 + num2) / denQuad; 
        int256 r1 = (num1 - num2) / denQuad;
        // int256 r0 = (-bQuad*MULTIPLIER + disc*MULTIPLIER) / aQuad.mul(two).muli(MULTIPLIER);
        // int256 r1 = (-bQuad*MULTIPLIER - disc*MULTIPLIER) / aQuad.mul(two).muli(MULTIPLIER);

        if(a < 0 && b < 0) utility = (r0 > r1) ? r1 : r0;
        else utility = (r0 > r1) ? r0 : r1;
        
        if (utility < 0) revert CurveError(utility);
    }

    /**
     * @dev Given a utility and a bonding curve (a, b, k) and one coordinate
     *  of a point on that curve, we can find the other coordinate of the
     *  point.
     * @dev the equation for a curve:
     *  ((x / (ku)) + a) ((y / (ku)) + b) = 1 (see _getUtility notes)
     * @dev Isolating y in the equation above gives us the equation:
     *  y = (k^2 u^2)/(a k u + x) - b k u
     * @dev This function returns x as xf because we want to be able to call
     *  getPointGivenX and getPointGivenY and handle the returned values
     *  without caring about which particular function is was called.
     */

    function _getPointGivenXandUtility(
        int256 x,
        int256 utility
    ) internal view returns (int256 x0, int256 y0) {
        int128 a = a();
        int128 b = b();

        int256 a_convert = a.muli(MULTIPLIER);
        int256 b_convert = b.muli(MULTIPLIER);
        x0 = x;
        
        int256 f_0 = ((( x0  * MULTIPLIER ) / utility) + a_convert);
        int256 f_1 = ((MULTIPLIER * MULTIPLIER / f_0) -  b_convert);
        int256 f_2 = (f_1 * utility) / MULTIPLIER; 
        y0 = f_2;

        if (y0 < 0) revert CurveError(y0);
    }

    /**
     * @dev Given a utility and a bonding curve (a, b, k) and one coordinate
     *  of a point on that curve, we can find the other coordinate of the
     *  point.
     * @dev the equation for a curve is:
     *  ((x / (ku)) + a) ((y / (ku)) + b) = 1 (see _getUtility notes)
     * @dev Isolating y in the equation above gives us the equation:
     *  x = (k^2 u^2)/(b k u + y) - a k u
     * @dev This function returns y as yf because we want to be able to call
     *  getPointGivenX and getPointGivenY and handle the returned values
     *  without caring about which particular function is was called.
     */
    function _getPointGivenYandUtility(
        int256 y,
        int256 utility
    ) internal view returns (int256 x0, int256 y0) {
        int128 a = a();
        int128 b = b();

        int256 a_convert = a.muli(MULTIPLIER);
        int256 b_convert = b.muli(MULTIPLIER);
        y0 = y;

        int256 f_0 = (( y0  * MULTIPLIER ) / utility) + b_convert;
        int256 f_1 = ( ((MULTIPLIER)*(MULTIPLIER) / f_0) - a_convert );
        int256 f_2 = (f_1 * utility) / (MULTIPLIER); 
        x0 = f_2;

        if (x0 < 0) revert CurveError(x0);
    }

 
    /**
     * @dev this limits the ratio between a starting balance and an input
     *  or output amount.
     * @dev when we swap very small amounts against a very large pool,
     *  precision errors can cause the pool to lose a small amount of value.
     */
    function _checkAmountWithBalance(uint256 balance, uint256 amount)
        private
        pure
    {
        if (balance / amount >= MAX_BALANCE_AMOUNT_RATIO) revert AmountError();
    }

    /**
     * @dev The pool's balances of the x reserve and y reserve tokens must be
     *  greater than or equal to the MIN_BALANCE
     * @dev The pool's ratio of y to x must be within the interval
     *  [MIN_M, MAX_M)
     */
    function _checkBalances(int256 x, int256 y) private pure {
        if (x < MIN_BALANCE || y < MIN_BALANCE) revert BalanceError(x,y);
        int128 finalBalanceRatio = y.divi(x);
        if (finalBalanceRatio < MIN_M) revert BoundaryError(x,y);
        else if (MAX_M <= finalBalanceRatio) revert BoundaryError(x,y);
    }

    /**
     * @dev Rounding and fees are equivalent concepts
     * @dev We charge fees by rounding values in directions that are beneficial
     *  to the pool.
     * @dev the BASE_FEE and FIXED_FEE values were chosen such that round
     *  enough to cover numerical stability issues that arise from using a
     *  fixed precision math library and piecewise bonding curves.
     */
    function _applyFeeByRounding(int256 amount, bool feeUp)
        private
        pure
        returns (int256 roundedAmount)
    {
        bool negative = amount < 0;
        uint256 absoluteValue = negative ? uint256(-amount) : uint256(amount);
        // FIXED_FEE * 2 because we will possibly deduct the FIXED_FEE from
        // this amount, and we don't want the final amount to be less than
        // the FIXED_FEE.
        if (absoluteValue < FIXED_FEE * 2) revert AmountError();

        uint256 roundedAbsoluteAmount;
        if (feeUp) {
            roundedAbsoluteAmount =
                absoluteValue +
                (absoluteValue / BASE_FEE) +
                FIXED_FEE;
            require(roundedAbsoluteAmount < INT_MAX);
        } else
            roundedAbsoluteAmount =
                absoluteValue -
                (absoluteValue / BASE_FEE) -
                FIXED_FEE;

        roundedAmount = negative
            ? -int256(roundedAbsoluteAmount)
            : int256(roundedAbsoluteAmount);
    }
}