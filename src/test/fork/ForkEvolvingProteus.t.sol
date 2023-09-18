pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../ocean/Interactions.sol";
import "../../ocean/Ocean.sol";
import "../../mocks/ERC20MintsToDeployer.sol";
import "..//EvolvingInstrumentedProteus.sol";
import "../../proteus/LiquidityPoolProxy.sol";

/**
   Fork Test Suite for Evolving Proteus to test back and forth swaps on each asset in a pool, multiple swaps, and deposits/withdrawals over time
   Invariants tested:
   1. The differences in pool token balances after a swap is same as the differences in user token balances after factoring in the fee
   2. Utility & utility/lp token supply does not decrease after swap
   3. For a deposit, utility will always increase, and util/lp does not decrease
   4. For a withdraw, utility will always decrease, and util/lp does not decrease

   The following invariants are soft invariants that apply for a back and forth swap scenarios (see tests below) and might not hold true when the user is expected to make profit at the end
    5. x price decreases over time & y price stays constant
      - when x is swapped at t0 user x bal after swap >= user x bal before swap & pool x bal before swap >= pool x bal after swap
      - when y is swapped at t0 user y bal after swap <= user y bal before swap & pool y bal before swap <= pool y bal after swap
    6. when x price increases over time & y price stays constant
      - when x is swapped at t0  user x bal after swap <= user x bal before swap & pool x bal before swap <= pool x bal after swap
      - when y is swapped at t0  user y bal after swap >= user y bal before swap & pool y bal before swap >= pool y bal after swap
    7. when y price decreases over time & x price stays constant
      - when x is swapped at t0 user x bal after swap >= user x bal before swap & pool x bal before swap >= pool x bal after swap
      - when y is swapped at t0 user y bal after swap <= user y bal before swap & pool y bal before swap <= pool y bal after swap
    8. when y price increases over time & x price stays constant
      - when x is swapped at t0 user x bal after swap <= user x bal before swap & pool x bal before swap <= pool x bal after swap
      - when y is swapped at t0 user y bal after swap >= user y bal before swap & pool y bal before swap >= pool y bal after swap
    9. when x & y prices both increase with time
      - when x is swapped at t0 user x bal after swap <= user x bal before swap & pool x bal before swap <= pool x bal after swap
      - when y is swapped at t0 user y bal after swap >= user y bal before swap & pool y bal before swap >= pool y bal after swap
    10. when x & y prices both decrease with time
      - when x is swapped at t0 user x bal after swap >= user x bal before swap & pool x bal before swap >= pool x bal after swap
      - when y is swapped at t0 user y bal after swap <= user y bal before swap & pool y bal before swap <= pool y bal after swap
    11. when x & y prices both stay constant
      - when x is swapped at t0 user x bal after swap <= user x bal before swap & pool x bal before swap <= pool x bal after swap
      - when y is swapped at t0 user y bal after swap <= user y bal before swap & pool y bal before swap <= pool y bal after swap
*/
contract ForkEvolvingProteus is Test {
  using ABDKMath64x64 for uint256;
  using ABDKMath64x64 for int256;
  using ABDKMath64x64 for int128;

  Ocean _ocean = Ocean(0xC32eB36f886F638fffD836DF44C124074cFe3584);
  ERC20MintsToDeployer _tokenA;
  address tokenOwner = 0x9b64203878F24eB0CDF55c8c6fA7D08Ba0cF77E5;
  EvolvingInstrumentedProteus _evolvingProteus;
  LiquidityPoolProxy _pool;

  uint256 _tokenA_OceanId; // deploying a new token
  uint256 _tokenB_OceanId = 68598205499637732940393479723998335974150219832588297998851264911405221787060;
  uint256 lpTokenId;
  bytes32 interactionIdToComputeOutputAmount;
  bytes32 interactionIdToWrapERC20TokenA;
  bytes32 interactionIdToUnWrapERC20TokenA;
  bytes32 interactionIdToUnWrapERC20TokenB;

  int256 constant BASE_FEE = 800; // baseFee refers to the % fee applied to the swap amount
  int256 constant FIXED_FEE = 10 ** 9; // fixedFee refers to the minimum fee applied to the swap amount
  uint256 constant T_DURATION =  3 days; 
  uint256 EVOLUTION_START_TIME =  block.timestamp + 1 days; 
  int128 constant ABDK_ONE = int128(int256(1 << 64));

  uint256 py_init_val;
  uint256 px_init_val;
  uint256 py_final_val;
  uint256 px_final_val;

  function setUp() public {
    vm.createSelectFork("https://arb1.arbitrum.io/rpc"); // Will start on latest block by default

    vm.prank(tokenOwner);
    _tokenA = new ERC20MintsToDeployer(type(uint256).max, 18);

    _tokenA_OceanId = uint256(keccak256(abi.encodePacked(address(_tokenA), uint(0))));

    // funding the arb whale with eth
    vm.deal(tokenOwner, type(uint256).max);

    vm.prank(tokenOwner);
    _pool = new LiquidityPoolProxy(
      _tokenA_OceanId,
      _tokenB_OceanId,
      address(_ocean),
      10_000_000 ether
    );
    
    // Note 
    /** 
      - At extreme edges of the bonding curve, precision issues may be encountered if using relatively small values for pool balances or specified amounts.
      - After a back and forth swap, some invariants may fail due to the swap fee when the pool makes money instead of the user making money
      - The assertWithinRounding check for utility may sometimes fail if using high price values and swap amounts since the utlility increases more than expected
      - Behavior when x and y prices are moving in opposite directions has not been tested and is considered out of scope.
      - Issues may occur if the pool balances, prices, and swap amounts are wildly different in their magnitudes. They should be scaled accordingly to test with different values.
    */

    // Different price ranges that are used for testing
    // x & y constant
    // small values
    py_init_val = 695000000000000;
    px_init_val = 692930500000000;
    py_final_val = 695000000000000;
    px_final_val = 692930500000000;
    
    // large values
    // py_final_val = 2000000000000000000000;
    // px_init_val =  990000000000000000;
    // py_init_val = 2000000000000000000000;
    // px_final_val = 990000000000000000;

    // extremely large values
    // py_final_val = 9e25;
    // px_init_val = 8e25;
    // py_init_val =  9e25;
    // px_final_val = 8e25;

    // x constant y increases
    // small values
    // py_init_val = 695000000000000;
    // px_init_val = 692930500000000;
    // py_final_val = 995000000000000;
    // px_final_val = 692930500000000;

    // large values
    // py_final_val = 4000000000000000000000;
    // px_init_val =  990000000000000000;
    // py_init_val = 2000000000000000000000;
    // px_final_val = 990000000000000000;

    // extremely large values
    // py_final_val = 9e25;
    // px_init_val = 6e25;
    // py_init_val =  8e25;
    // px_final_val = 6e25;

    // x constant y decreases
    // small values
    // py_final_val = 695000000000000;
    // px_init_val = 692930500000000;
    // py_init_val = 995000000000000;
    // px_final_val = 692930500000000;

    // large values
    // py_init_val = 4000000000000000000000;
    // px_init_val =  690000000000000000;
    // py_final_val = 2000000000000000000000;
    // px_final_val = 690000000000000000;

    // extremely large values
    // py_init_val = 9e25;
    // px_init_val = 7e25;
    // py_final_val =  8e25;
    // px_final_val = 7e25;

    //y constant x decreases
    // small values
    // py_final_val = 995000000000000;
    // px_init_val = 992930500000000;
    // py_init_val = 995000000000000;
    // px_final_val = 692930500000000;

    // large values
    // py_init_val = 4000000000000000000000;
    // px_init_val =  790000000000000000;
    // py_final_val = 4000000000000000000000;
    // px_final_val = 490000000000000000;

    // extremely large values
    // py_init_val = 9e25;
    // px_init_val = 8e25;
    // py_final_val =  9e25;
    // px_final_val = 6e25;
    
    // y constant x increases
    // small values
    // py_final_val = 995000000000000;
    // px_final_val = 992930500000000;
    // py_init_val = 995000000000000;
    // px_init_val = 692930500000000;

    // large values
    // py_final_val = 4000000000000000000000;
    // px_final_val = 790000000000000000;
    // py_init_val = 4000000000000000000000;
    // px_init_val = 490000000000000000;

    // extremely large values
    // py_init_val = 9e25;
    // px_final_val = 8e25;
    // py_final_val =  9e25;
    // px_init_val = 6e25;

    // x & y both decrease
    // small values
    // py_final_val = 4950000000000000;
    // px_final_val = 434900500000000;
    // py_init_val =  9995000000000000;
    // px_init_val =  989400050000000;

    // large values
    // py_final_val = 1000000000000000000000;
    // px_final_val = 490000000000000000;
    // py_init_val = 4000000000000000000000;
    // px_init_val = 790000000000000000;

    // extremely large values
    // py_final_val = 8e25;
    // px_init_val = 7e25;
    // py_init_val =  9e25;
    // px_final_val = 6e25;

    // x & y both increase
    // small values
    // py_init_val = 4950000000000000;
    // px_init_val = 434900500000000;
    // py_final_val =  9995000000000000;
    // px_final_val =  989400050000000;

    // large values
    // py_init_val = 1000000000000000000000;
    // px_init_val = 490000000000000000;
    // py_final_val = 4000000000000000000000;
    // px_final_val = 790000000000000000;

    // extremely large values
    // py_init_val = 8e25;
    // px_final_val = 7e25;
    // py_final_val =  9e25;
    // px_init_val = 6e25;
    
    // using abdk math to handle the prices with precision
    int128 py_init = ABDKMath64x64.divu(py_init_val, 1e18);
    int128 px_init = ABDKMath64x64.divu(px_init_val, 1e18);
    int128 py_final = ABDKMath64x64.divu(py_final_val, 1e18);
    int128 px_final = ABDKMath64x64.divu(px_final_val, 1e18);

    vm.prank(tokenOwner);
    _evolvingProteus = new EvolvingInstrumentedProteus(
      py_init,
      px_init,
      py_final,
      px_final,
      EVOLUTION_START_TIME,
      T_DURATION
    );

    vm.prank(tokenOwner);
    _pool.setImplementation(address(_evolvingProteus));
    lpTokenId = _pool.lpTokenId();

    interactionIdToComputeOutputAmount = _fetchInteractionId(address(_pool), uint256(InteractionType.ComputeOutputAmount));
    interactionIdToWrapERC20TokenA = _fetchInteractionId(address(_tokenA), uint256(InteractionType.WrapErc20));
    interactionIdToUnWrapERC20TokenA = _fetchInteractionId(address(_tokenA), uint256(InteractionType.UnwrapErc20));
    interactionIdToUnWrapERC20TokenB = _fetchInteractionId(address(0), uint256(InteractionType.UnwrapEther));

    Interaction[] memory interactions = new Interaction[](3);
    // mint shell tokens
    interactions[0] = Interaction({
      interactionTypeAndAddress: interactionIdToWrapERC20TokenA,
      inputToken: 0,
      outputToken: 0,
      specifiedAmount: 100_000_000 ether,
      metadata: bytes32(0)
    });

    // adding liquidity
    interactions[1] = Interaction({
      interactionTypeAndAddress: interactionIdToComputeOutputAmount,
      inputToken: _tokenA_OceanId,
      outputToken: lpTokenId,
      specifiedAmount: 100_000_000 ether,
      metadata: bytes32(0)
    });

    interactions[2] = Interaction({
      interactionTypeAndAddress: interactionIdToComputeOutputAmount,
      inputToken: _tokenB_OceanId,
      outputToken: lpTokenId,
      specifiedAmount: 90_000 ether,
      metadata: bytes32(0)
    });

    // erc1155 token id's for balance delta
    uint256[] memory ids = new uint256[](3);
    ids[0] = _tokenA_OceanId;
    ids[1] = _tokenB_OceanId;
    ids[2] = lpTokenId;

    vm.prank(tokenOwner);
    // approving ocean to spend tokens
    IERC20(address(_tokenA)).approve(address(_ocean), 100_000_000 ether);

    vm.prank(tokenOwner);
    _ocean.doMultipleInteractions{ value: 90_000 ether }(interactions, ids);
  }

  /** 
    Logs all the curve equation related parameters
  */
  function _logPoolParams() internal {
    (, , , , uint t_init, uint t_final,) = _evolvingProteus.params();

    (uint256 xBalanceAfterDeposit, uint256 yBalanceAfterDeposit) = _getBalances();
    int256 utility = _evolvingProteus.getUtility(int256(xBalanceAfterDeposit), int256(yBalanceAfterDeposit));

    emit log("utility");
    emit log_int(utility);
    emit log("a");
    emit log_int(_evolvingProteus.a());
    emit log("b");
    emit log_int(_evolvingProteus.b());
    emit log("p_min");
    emit log_int(_evolvingProteus.p_min());
    emit log("p_max");
    emit log_int(_evolvingProteus.p_max());
    emit log("t()");
    emit log_int(_evolvingProteus.t());
  }

  /**
    used to fetch the ocean interaction id for accounting purposes
  */
  function _fetchInteractionId(
    address token,
    uint256 interactionType
  ) internal pure returns (bytes32) {
    uint256 packedValue = uint256(uint160(token));
    packedValue |= interactionType << 248;
    return bytes32(abi.encode(packedValue));
  }

  /**
    fetch pool balances
  */
  function _getBalances() internal view returns (uint256 xBalance, uint256 yBalance) {
    address[] memory accounts = new address[](2);
    uint256[] memory ids = new uint256[](2);

    accounts[0] = accounts[1] = address(_pool);
    ids[0] = _tokenA_OceanId;
    ids[1] = _tokenB_OceanId;

    uint256[] memory result = _ocean.balanceOfBatch(accounts, ids);
    (xBalance, yBalance) = (result[0], result[1]);
  }

  /**
    fetch pool supply
  */
  function _getTotalSupply() internal view returns (uint256 supply) {
    supply = _pool.getTokenSupply(lpTokenId);
  }

  /**
    calculate balance difference
  */
  function _getBalanceDiffAfterSwaps(uint256 _beforeSwapBalance, bool tokenA_Diff) internal view returns(uint256 _diff) {
    uint256 _afterSwapBalance;
    if (tokenA_Diff) _afterSwapBalance = IERC20(address(_tokenA)).balanceOf(tokenOwner);
    else _afterSwapBalance = tokenOwner.balance;

    return _afterSwapBalance - _beforeSwapBalance;
  }


  /**
    swap token a amount for token b
    @param _amount amount to swap
  */
  function _swapWithTokenAInputAmount(uint256 _amount) internal {
    // swap token a to token b
    (uint256 xBalanceBeforeSwap, uint256 yBalanceBeforeSwap) = _getBalances();
    int256 utilityBeforeSwap = _evolvingProteus.getUtility(int256(xBalanceBeforeSwap), int256(yBalanceBeforeSwap));
    int128 utilityPerLpBeforeSwap = uint256(utilityBeforeSwap).divu(_getTotalSupply());

    uint256 _tokenATraderBalanceBeforeSwap = IERC20(address(_tokenA)).balanceOf(tokenOwner);
    uint256 _tokenBTraderBalanceBeforeSwap = tokenOwner.balance;

    {
    Interaction[] memory interactions = new Interaction[](3);
    // wrap
    interactions[0] = Interaction({
      interactionTypeAndAddress: interactionIdToWrapERC20TokenA,
      inputToken: 0,
      outputToken: 0,
      specifiedAmount: _amount,
      metadata: bytes32(0)
    });
    // swap
    interactions[1] = Interaction({
      interactionTypeAndAddress: interactionIdToComputeOutputAmount,
      inputToken: _tokenA_OceanId,
      outputToken: _tokenB_OceanId,
      specifiedAmount: _amount,
      metadata: bytes32(0)
    });

    // unwrap ether
    interactions[2] = Interaction({
      interactionTypeAndAddress: interactionIdToUnWrapERC20TokenB,
      inputToken: 0,
      outputToken: 0,
      specifiedAmount: type(uint256).max,
      metadata: bytes32(0)
    });

    // erc1155 token id's for balance delta
    uint256[] memory ids = new uint256[](2);
    ids[0] = _tokenA_OceanId;
    ids[1] = _tokenB_OceanId;

    vm.prank(tokenOwner);
    _tokenA.approve(address(_ocean), _amount);

    vm.prank(tokenOwner);
    _ocean.doMultipleInteractions(interactions, ids);
    }
    
    (uint256 xBalanceAfterSwap, uint256 yBalanceAfterSwap) = _getBalances();
    int256 utilityAfterSwap = _evolvingProteus.getUtility(int256(xBalanceAfterSwap), int256(yBalanceAfterSwap));
    int128 utilityPerLpAfterSwap = uint256(utilityAfterSwap).divu(_getTotalSupply());
    
    // logging user balances, utility, pool parameters after the swap
    emit log("x before and after x->y swap");
    emit log_uint(xBalanceBeforeSwap);
    emit log_uint(xBalanceAfterSwap);
    emit log("y before and after x->y swap");
    emit log_uint(yBalanceBeforeSwap);
    emit log_uint(yBalanceAfterSwap);
    emit log("utility before and after x->y swap");
    emit log_int(utilityBeforeSwap);
    emit log_int(utilityAfterSwap);
    emit log("utility per lp before and after swap");
    emit log_int(utilityPerLpBeforeSwap);
    emit log_int(utilityPerLpAfterSwap);
    emit log("a & b values");
    emit log_int(_evolvingProteus.a());
    emit log_int(_evolvingProteus.b());
    
    // assertion checks for utility, utility per lp, user token balances, curve parameters
    uint256 xBalDiff = xBalanceAfterSwap - xBalanceBeforeSwap;
    uint256 yBalDiff = yBalanceBeforeSwap - yBalanceAfterSwap;

    uint256 _tokenATraderBalanceAfterSwap = IERC20(address(_tokenA)).balanceOf(tokenOwner);
    uint256 _tokenBTraderBalanceAfterSwap = tokenOwner.balance;

    uint256 _tokenBBalDiff = _tokenBTraderBalanceAfterSwap - _tokenBTraderBalanceBeforeSwap;
    uint256 _tokenABalDiff = _tokenATraderBalanceBeforeSwap - _tokenATraderBalanceAfterSwap;

    assertWithinRounding(utilityAfterSwap, utilityBeforeSwap);
    assertWithinRounding(utilityPerLpAfterSwap, utilityPerLpBeforeSwap);
    assertWithinRounding(int256(_tokenBBalDiff), int256(yBalDiff));
    assertWithinRounding(int256(_tokenABalDiff), int256(xBalDiff));
    assertGt(_tokenBTraderBalanceAfterSwap, _tokenBTraderBalanceBeforeSwap);
    assertLt(_tokenATraderBalanceAfterSwap, _tokenATraderBalanceBeforeSwap);
    assertGt(_evolvingProteus.p_max(), _evolvingProteus.p_min());
  }

  /**
    swap token b amount for token a
    @param _amount amount to swap
  */
  function _swapWithTokenBInputAmount(uint256 _amount) internal {
    // swap token b to token a
    (uint256 xBalanceBeforeSwap, uint256 yBalanceBeforeSwap) = _getBalances();
    int256 utilityBeforeSwap = _evolvingProteus.getUtility(int256(xBalanceBeforeSwap), int256(yBalanceBeforeSwap));

    uint256 _tokenATraderBalanceBeforeSwap = IERC20(address(_tokenA)).balanceOf(tokenOwner);
    uint256 _tokenBTraderBalanceBeforeSwap = tokenOwner.balance;
    int128 utilityPerLpBeforeSwap = uint256(utilityBeforeSwap).divu(_getTotalSupply());

    {
    Interaction[] memory interactions = new Interaction[](2);
    // swap
    interactions[0] = Interaction({
      interactionTypeAndAddress: interactionIdToComputeOutputAmount,
      inputToken: _tokenB_OceanId,
      outputToken: _tokenA_OceanId,
      specifiedAmount: _amount,
      metadata: bytes32(0)
    });
    // unwrap
    interactions[1] = Interaction({
      interactionTypeAndAddress: interactionIdToUnWrapERC20TokenA,
      inputToken: 0,
      outputToken: 0,
      specifiedAmount: type(uint256).max,
      metadata: bytes32(0)
    });

    // erc1155 token id's for balance delta
    uint256[] memory ids = new uint256[](2);
    ids[0] = _tokenA_OceanId;
    ids[1] = _tokenB_OceanId;

    vm.prank(tokenOwner);
    _ocean.doMultipleInteractions{ value: _amount }(interactions, ids);
    }

    (uint256 xBalanceAfterSwap, uint256 yBalanceAfterSwap) = _getBalances();

    int256 utilityAfterSwap = _evolvingProteus.getUtility(int256(xBalanceAfterSwap), int256(yBalanceAfterSwap));
    int128 utilityPerLpAfterSwap = uint256(utilityAfterSwap).divu(_getTotalSupply());

    uint256 _tokenATraderBalanceAfterSwap = IERC20(address(_tokenA)).balanceOf(tokenOwner);
    uint256 _tokenBTraderBalanceAfterSwap = tokenOwner.balance;

    uint256 xBalDiff = xBalanceBeforeSwap - xBalanceAfterSwap;
    uint256 yBalDiff = yBalanceAfterSwap - yBalanceBeforeSwap;

    // logging user balances, utility, pool parameters after the swap
    emit log("x before and after y->x swap");
    emit log_uint(xBalanceBeforeSwap);
    emit log_uint(xBalanceAfterSwap);
    emit log("y before and after y->x swap");
    emit log_uint(yBalanceBeforeSwap);
    emit log_uint(yBalanceAfterSwap);
    emit log("utility before and after y->x swap");
    emit log_int(utilityBeforeSwap);
    emit log_int(utilityAfterSwap);
    emit log("utility per lp before and after swap");
    emit log_int(utilityPerLpBeforeSwap);
    emit log_int(utilityPerLpAfterSwap);
    emit log("a & b values");
    emit log_int(_evolvingProteus.a());
    emit log_int(_evolvingProteus.b());

    // assertion checks for utility, utility per lp, user token balances, curve parameters
    uint256 _tokenBBalDiff = _tokenBTraderBalanceBeforeSwap - _tokenBTraderBalanceAfterSwap;
    uint256 _tokenABalDiff = _tokenATraderBalanceAfterSwap - _tokenATraderBalanceBeforeSwap;

    assertWithinRounding(utilityAfterSwap, utilityBeforeSwap);
    assertWithinRounding(utilityPerLpAfterSwap, utilityPerLpBeforeSwap);
    assertWithinRounding(int256(_tokenBBalDiff), int256(yBalDiff));
    assertWithinRounding(int256(_tokenABalDiff), int256(xBalDiff));
    assertLt(_tokenBTraderBalanceAfterSwap, _tokenBTraderBalanceBeforeSwap);
    assertGt(_tokenATraderBalanceAfterSwap, _tokenATraderBalanceBeforeSwap);
    assertGt(_evolvingProteus.p_max(), _evolvingProteus.p_min());
  }

  /**
    add liquidity to the pool
    @param _amount token amount to deposit
  */
  function _addLiquidity(uint256 _amount) internal {
    (uint256 xBalanceBeforeDeposit, uint256 yBalanceBeforeDeposit) = _getBalances();
    int256 utilityBeforeDeposit = _evolvingProteus.getUtility(int256(xBalanceBeforeDeposit), int256(yBalanceBeforeDeposit));
    int128 utilityPerLpBeforeDeposit = uint256(utilityBeforeDeposit).divu(_getTotalSupply());

    Interaction[] memory interactions = new Interaction[](3);
    // wrap
    interactions[0] = Interaction({
      interactionTypeAndAddress: interactionIdToWrapERC20TokenA,
      inputToken: 0,
      outputToken: 0,
      specifiedAmount: _amount * 15,
      metadata: bytes32(0)
    });
    // deposit token a
    interactions[1] = Interaction({
      interactionTypeAndAddress: interactionIdToComputeOutputAmount,
      inputToken: _tokenA_OceanId,
      outputToken: lpTokenId,
      specifiedAmount: _amount * 15,
      metadata: bytes32(0)
    });
    // deposit token b
    interactions[2] = Interaction({
      interactionTypeAndAddress: interactionIdToComputeOutputAmount,
      inputToken: _tokenB_OceanId,
      outputToken: lpTokenId,
      specifiedAmount: _amount,
      metadata: bytes32(0)
    });

    // erc1155 token id's for balance delta
    uint256[] memory ids = new uint256[](3);
    ids[0] = _tokenA_OceanId;
    ids[1] = _tokenB_OceanId;
    ids[2] = lpTokenId;

    vm.prank(tokenOwner);
    _tokenA.approve(address(_ocean), _amount * 15);

    vm.prank(tokenOwner);
    _ocean.doMultipleInteractions{ value: _amount }(interactions, ids);

    (uint256 xBalanceAfterDeposit, uint256 yBalanceAfterDeposit) = _getBalances();
    int256 utilityAfterDeposit = _evolvingProteus.getUtility(int256(xBalanceAfterDeposit), int256(yBalanceAfterDeposit));
    int128 utilityPerLpAfterDeposit = uint256(utilityAfterDeposit).divu(_getTotalSupply());

    // logging user balances, utility, pool parameters after the swap
    emit log("x before and after deposit");
    emit log_uint(xBalanceBeforeDeposit);
    emit log_uint(xBalanceAfterDeposit);
    emit log("y before and after deposit");
    emit log_uint(yBalanceBeforeDeposit);
    emit log_uint(yBalanceAfterDeposit);
    emit log("utility before and after deposit");
    emit log_int(utilityBeforeDeposit);
    emit log_int(utilityAfterDeposit);
    emit log("utility per lp before and after deposit");
    emit log_int(utilityPerLpBeforeDeposit);
    emit log_int(utilityPerLpAfterDeposit);
    emit log("a & b values");
    emit log_int(_evolvingProteus.a());
    emit log_int(_evolvingProteus.b());

    // assertion checks for utility, utility per lp, curve parameters
    assertGt(utilityAfterDeposit, utilityBeforeDeposit);
    assertGt(utilityPerLpAfterDeposit, utilityPerLpBeforeDeposit);
    assertGt(_evolvingProteus.p_max(), _evolvingProteus.p_min());
  }

  /**
    remove liquidity from the pool
    @param _amount token amount to withdraw
  */
  function _removeLiquidity(uint256 _amount) internal {
    uint256 _lpBalanceBeforeDeposit = _ocean.balanceOf(tokenOwner, lpTokenId);
    _addLiquidity(_amount);

    uint256 _lpBalanceAfterDeposit = _ocean.balanceOf(tokenOwner, lpTokenId);
    uint256 _lpBalanceDiff = _lpBalanceAfterDeposit - _lpBalanceBeforeDeposit;

    (uint256 xBalanceBeforeWithdraw, uint256 yBalanceBeforeWithdraw) = _getBalances();
    int256 utilityBeforeWithdraw = _evolvingProteus.getUtility(int256(xBalanceBeforeWithdraw), int256(yBalanceBeforeWithdraw));
    int128 utilityPerLpBeforeWithdraw = uint256(utilityBeforeWithdraw).divu(_getTotalSupply());
    
    // remove liquidity
    Interaction[] memory interactions = new Interaction[](4);
    // remove and get token a
    interactions[0] = Interaction({
      interactionTypeAndAddress: interactionIdToComputeOutputAmount,
      inputToken: lpTokenId,
      outputToken: _tokenA_OceanId,
      specifiedAmount: _lpBalanceDiff / 2,
      metadata: bytes32(0)
    });
    // unwrap token a
    interactions[1] = Interaction({
      interactionTypeAndAddress: interactionIdToUnWrapERC20TokenA,
      inputToken: 0,
      outputToken: 0,
      specifiedAmount: type(uint256).max,
      metadata: bytes32(0)
    });
    // remove and get token b
    interactions[2] = Interaction({
      interactionTypeAndAddress: interactionIdToComputeOutputAmount,
      inputToken: lpTokenId,
      outputToken: _tokenB_OceanId,
      specifiedAmount: _lpBalanceDiff / 2,
      metadata: bytes32(0)
    });
    // unwrap token b
    interactions[3] = Interaction({
      interactionTypeAndAddress: interactionIdToUnWrapERC20TokenB,
      inputToken: 0,
      outputToken: 0,
      specifiedAmount: type(uint256).max,
      metadata: bytes32(0)
    });

     // erc1155 token id's for balance delta
    uint256[] memory ids = new uint256[](3);
    ids[0] = _tokenA_OceanId;
    ids[1] = _tokenB_OceanId;
    ids[2] = lpTokenId;

    vm.prank(tokenOwner);
    _ocean.doMultipleInteractions(interactions, ids);

    (uint256 xBalanceAfterWithdrawal, uint256 yBalanceAfterWithdrawal) = _getBalances();
    int256 utilityAfterWithdraw = _evolvingProteus.getUtility(int256(xBalanceAfterWithdrawal), int256(yBalanceAfterWithdrawal));
    int128 utilityPerLpAfterWithdraw = uint256(utilityAfterWithdraw).divu(_getTotalSupply());

    // logging user balances, utility, pool parameters after the swap
    emit log("x before and after withdrawal");
    emit log_uint(xBalanceBeforeWithdraw);
    emit log_uint(xBalanceAfterWithdrawal);
    emit log("y before and after withdrawal");
    emit log_uint(yBalanceBeforeWithdraw);
    emit log_uint(yBalanceAfterWithdrawal);
    emit log("utility before and after withdrawal");
    emit log_int(utilityBeforeWithdraw);
    emit log_int(utilityAfterWithdraw);
    emit log("utility per lp before and after withdrawal");
    emit log_int(utilityPerLpBeforeWithdraw);
    emit log_int(utilityPerLpAfterWithdraw);
    emit log("a & b values");
    emit log_int(_evolvingProteus.a());
    emit log_int(_evolvingProteus.b());

    // assertion checks for utility, utility per lp, curve parameters
    assertGt(utilityBeforeWithdraw, utilityAfterWithdraw);
    assertLt(utilityPerLpBeforeWithdraw, utilityPerLpAfterWithdraw);
    assertGt(_evolvingProteus.p_max(), _evolvingProteus.p_min());
  }


  /**
    test to check a reverse swap i.e
    at time t0 swap y -> x
    at time t1 swap x -> y
    
    in the scenario's when user is expected to make a profit we have use assertApproxEqRel to take in fee, rounding factor with extremely large price values and the delta % is based on testing with the extremely large price values
    Note: The assertions for y constant x increases & x and y both increase invariant scenario reverts due to extreme slippage when tested with extremely large prices mentioned in the setUp method so that is a known outcome
    @param _amount token amount to withdraw
  */
  function testReverseSwapY(uint256 _amount, uint256 _time) public {
    _amount = bound(_amount, 20 ether, 100 ether);
    _time = bound(_time, 100, T_DURATION);

    vm.warp(EVOLUTION_START_TIME + 1);

    if (tokenOwner.balance > _amount ) {
      // swap first from b -> a & a -> b

      (,uint256 yBalanceBeforeSwap) = _getBalances();
      uint256 _tokenBTraderBalanceBeforeSwap = tokenOwner.balance;
      uint256 _tokenATraderBalanceBeforeSwap = IERC20(address(_tokenA)).balanceOf(tokenOwner);
      _swapWithTokenBInputAmount(_amount);
      uint256 _diffAmount = _getBalanceDiffAfterSwaps(_tokenATraderBalanceBeforeSwap, true);

      _logPoolParams();
      vm.warp(block.timestamp + _time);
      _swapWithTokenAInputAmount(_diffAmount);
      _logPoolParams();

      (,uint256 yBalanceAfterSwap) = _getBalances();
      uint256 _tokenBTraderBalanceAfterSwap = tokenOwner.balance;
   
      // assertion for invariants based on the price confgurations
      if (px_final_val < px_init_val && py_final_val < py_init_val) {
          assertLe(_tokenBTraderBalanceAfterSwap, _tokenBTraderBalanceBeforeSwap);
          assertGe(yBalanceAfterSwap, yBalanceBeforeSwap);
      } else if (px_final_val > px_init_val && py_final_val > py_init_val) {
          // as per the soft invariant user is expected to make a profit but due to fee the get a slightly less amount
          assertApproxEqRel(_tokenBTraderBalanceAfterSwap, _tokenBTraderBalanceBeforeSwap, 0.00001e18);
          assertApproxEqRel(yBalanceAfterSwap, yBalanceBeforeSwap, 0.0009e18);
      } else if (px_final_val < px_init_val && py_final_val == py_init_val) {
          assertLe(_tokenBTraderBalanceAfterSwap, _tokenBTraderBalanceBeforeSwap);
          assertGe(yBalanceAfterSwap, yBalanceBeforeSwap);
      }  else if (px_final_val > px_init_val && py_final_val == py_init_val) {
          // as per the soft invariant user is expected to make a profit but due to fee the get a slightly less amount
          assertApproxEqRel(_tokenBTraderBalanceAfterSwap, _tokenBTraderBalanceBeforeSwap, 0.00001e18);
          assertApproxEqRel(yBalanceAfterSwap, yBalanceBeforeSwap, 0.0009e18);
      } else if (px_final_val == px_init_val && py_final_val < py_init_val) {
          assertLe(_tokenBTraderBalanceAfterSwap, _tokenBTraderBalanceBeforeSwap);
          assertGe(yBalanceAfterSwap, yBalanceBeforeSwap);
      } else if (px_final_val == px_init_val && py_final_val > py_init_val) {
          // as per the soft invariant user is expected to make a profit but due to fee the get a slightly less amount
          assertApproxEqRel(_tokenBTraderBalanceAfterSwap, _tokenBTraderBalanceBeforeSwap, 0.00001e18);
          assertApproxEqRel(yBalanceAfterSwap, yBalanceBeforeSwap, 0.0009e18);
      } else {
          assertLe(_tokenBTraderBalanceAfterSwap, _tokenBTraderBalanceBeforeSwap);
          assertGe(yBalanceAfterSwap, yBalanceBeforeSwap);
      }
    }
  }

  /**
    test to check a reverse swap i.e
    at time t0 swap x -> y
    at time t1 swap y -> x

    in the scenario's when user is expected to make a profit we have use assertApproxEqRel to take in fee, rounding factor with extremely large price values and the delta % is based on testing with the extremely large price values
    @param _amount token amount to withdraw
  */
  function testReverseSwapX(uint256 _amount, uint256 _time) public {
    _amount = bound(_amount, 50 ether, 50000 ether);
    _time = bound(_time, 100, T_DURATION);

    vm.warp(EVOLUTION_START_TIME + 1);

    if ((IERC20(address(_tokenA)).balanceOf(tokenOwner) > _amount)) {
      // swap first from a -> b & b -> a

      (uint256 xBalanceBeforeSwap,) = _getBalances();
      uint _tokenATraderBalanceBeforeSwap = IERC20(address(_tokenA)).balanceOf(tokenOwner);
      uint _tokenBTraderBalanceBeforeSwap = tokenOwner.balance;

      _swapWithTokenAInputAmount(_amount);
      uint256 _diffAmount = _getBalanceDiffAfterSwaps(_tokenBTraderBalanceBeforeSwap, false);

      _logPoolParams();
      vm.warp(block.timestamp + _time);
      _swapWithTokenBInputAmount(_diffAmount);
      _logPoolParams();
      
      (uint256 xBalanceAfterSwap,) = _getBalances();
      uint256 _tokenATraderBalanceAfterSwap = IERC20(address(_tokenA)).balanceOf(tokenOwner);

      // assertion for invariants based on the price confgurations
      if (px_final_val < px_init_val && py_final_val < py_init_val) {
          // as per the soft invariant user is expected to make a profit but due to fee the get a slightly less amount
          assertApproxEqRel(_tokenATraderBalanceAfterSwap, _tokenATraderBalanceBeforeSwap, 0.00001e18);
          assertApproxEqRel(xBalanceAfterSwap, xBalanceBeforeSwap, 0.0009e18);
      } else if (px_final_val > px_init_val && py_final_val > py_init_val) {
          assertLe(_tokenATraderBalanceAfterSwap, _tokenATraderBalanceBeforeSwap);
          assertGe(xBalanceAfterSwap, xBalanceBeforeSwap);
      } else if (px_final_val < px_init_val && py_final_val == py_init_val) {
          // as per the soft invariant user is expected to make a profit but due to fee the get a slightly less amount
          assertApproxEqRel(_tokenATraderBalanceAfterSwap, _tokenATraderBalanceBeforeSwap, 0.00001e18);
          assertApproxEqRel(xBalanceAfterSwap, xBalanceBeforeSwap, 0.0009e18);
      }  else if (px_final_val > px_init_val && py_final_val == py_init_val) {
          assertLe(_tokenATraderBalanceAfterSwap, _tokenATraderBalanceBeforeSwap);
          assertGe(xBalanceAfterSwap, xBalanceBeforeSwap);
      } else if (px_final_val == px_init_val && py_final_val < py_init_val) {
          // as per the soft invariant user is expected to make a profit but due to fee the get a slightly less amount
          assertApproxEqRel(_tokenATraderBalanceAfterSwap, _tokenATraderBalanceBeforeSwap, 0.00001e18);
          assertApproxEqRel(xBalanceAfterSwap, xBalanceBeforeSwap, 0.0009e18);
      } else if (px_final_val == px_init_val && py_final_val > py_init_val) {
          assertLe(_tokenATraderBalanceAfterSwap, _tokenATraderBalanceBeforeSwap);
          assertGe(xBalanceAfterSwap, xBalanceBeforeSwap);
      } else {
          assertLe(_tokenATraderBalanceAfterSwap, _tokenATraderBalanceBeforeSwap);
          assertGe(xBalanceAfterSwap, xBalanceBeforeSwap);
      }
    }
  }

  /**
    test to swap multiple times in different directions
    @param _amount token amount to swap
  // */
  function testMultipleSwaps(uint256 _amount) public {
    _amount = bound(_amount, 50 ether, 500 ether);

    vm.warp(EVOLUTION_START_TIME + 1);

    if (tokenOwner.balance > _amount) {
      uint _tokenATraderBalanceBeforeSwap = IERC20(address(_tokenA)).balanceOf(tokenOwner);
      _swapWithTokenBInputAmount(_amount);
      uint256 _diffAmount = _getBalanceDiffAfterSwaps(_tokenATraderBalanceBeforeSwap, true);

      _logPoolParams();
      _swapWithTokenAInputAmount(_diffAmount);
      _logPoolParams();
    }
  }

  /**
    test to swap multiple times in different directions over different time periods
    @param _amount token amount to swap
    @param _time time duration
  */
  function testMultipleSwapsOverDuration(uint256 _amount, uint256 _time) public {
    _amount = bound(_amount, 50 ether, 500 ether);
    _time = bound(_time, 0, T_DURATION);

    vm.warp(EVOLUTION_START_TIME + 1);

    if (tokenOwner.balance > _amount) {
    uint _tokenATraderBalanceBeforeSwap = IERC20(address(_tokenA)).balanceOf(tokenOwner);
    _swapWithTokenBInputAmount(_amount);
    uint256 _diffAmount = _getBalanceDiffAfterSwaps(_tokenATraderBalanceBeforeSwap, true);    
    _logPoolParams();
    
    uint _tokenBTraderBalanceBeforeSwap = tokenOwner.balance;
    vm.warp(block.timestamp + _time + (_time / 5));
    _swapWithTokenAInputAmount(_diffAmount);
    _diffAmount = _getBalanceDiffAfterSwaps(_tokenBTraderBalanceBeforeSwap, false);    
    _logPoolParams();

    _tokenATraderBalanceBeforeSwap = IERC20(address(_tokenA)).balanceOf(tokenOwner);
    vm.warp(block.timestamp + _time + (_time / 5));
    _swapWithTokenBInputAmount(_diffAmount);
    _diffAmount = _getBalanceDiffAfterSwaps(_tokenATraderBalanceBeforeSwap, true);    
    _logPoolParams();

    vm.warp(block.timestamp + _time + (_time / 5));
    _swapWithTokenAInputAmount(_diffAmount);
    _logPoolParams();
    }
  }

  /**
    test to deposit multiple times
    @param _amount token amount to swap
  */
  function testDeposit(uint256 _amount) public {
    _amount = bound(_amount, 5 ether, 500 ether);

    vm.warp(EVOLUTION_START_TIME + 1);

    if (tokenOwner.balance > _amount) {
    _swapWithTokenBInputAmount(_amount);
    _logPoolParams();
    _addLiquidity(_amount);
    _logPoolParams();
    }
  }

  /**
    test to deposit multiple times over different time periods
    @param _amount token amount to deposit
    @param _time time duration
  */
  function testDepositOverDuration(uint256 _amount, uint256 _time) public {
    _amount = bound(_amount, 5 ether, 500 ether);
    _time = bound(_time, 0, T_DURATION);

    vm.warp(EVOLUTION_START_TIME + 1);

    if (tokenOwner.balance > _amount) {
    _swapWithTokenBInputAmount(_amount);
    _logPoolParams();
    vm.warp(block.timestamp + _time + (_time / 3));
    _addLiquidity(_amount);

    _logPoolParams();

    vm.warp(block.timestamp + _time + (_time / 3));
    _addLiquidity(_amount / 4);
    _logPoolParams();
    }
  }

  /**
    test to withdraw multiple times 
    @param _amount token amount to withdraw
  */
  function testWithdraw(uint256 _amount) public {
    _amount = bound(_amount, 5 ether, 500 ether);

    vm.warp(EVOLUTION_START_TIME + 1);

    if (IERC20(address(_tokenA)).balanceOf(tokenOwner) > _amount) {
    _swapWithTokenAInputAmount(_amount);
    _logPoolParams();
    _removeLiquidity(_amount);
    _logPoolParams();
    }
  }


  /**
    test to withdraw multiple times over different time periods
    @param _amount token amount to withdraw
    @param _time time duration
  */
  function testWithdrawOverDuration(uint256 _amount, uint256 _time) public {
    _amount = bound(_amount, 5 ether, 500 ether);
    _time = bound(_time, 0, T_DURATION);

    vm.warp(EVOLUTION_START_TIME + 1);

    if (IERC20(address(_tokenA)).balanceOf(tokenOwner) > _amount) {
    _swapWithTokenAInputAmount(_amount);
    _logPoolParams();

    vm.warp(block.timestamp + _time + (_time / 3));
    _removeLiquidity(_amount);
    _logPoolParams();

    vm.warp(block.timestamp + _time + (_time / 3));
    _removeLiquidity(_amount / 3);
    _logPoolParams();
    }
  }
  
  // rounding assertions considering the fees
  function assertWithinRounding(int256 a0, int256 a1) internal {
    assertLe(
      (a0) - (a0 / BASE_FEE) - FIXED_FEE,
      a1,
      "not within less than rounding"
    );
    assertGe(
      (a0) + (a0 / BASE_FEE) + FIXED_FEE,
      a1,
      "not within greater than rounding"
    );
  }
}