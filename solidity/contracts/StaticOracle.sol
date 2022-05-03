// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol';
import '@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol';
import '../interfaces/IStaticOracle.sol';

/// @title Uniswap V3 Static Oracle
/// @notice Oracle contract for price quoting against Uniswap V3 pools
contract StaticOracle is IStaticOracle {
  /// @inheritdoc IStaticOracle
  IUniswapV3Factory public immutable override factory;
  /// @inheritdoc IStaticOracle
  uint8 public immutable override cardinalityPerMinute;
  uint24[] internal knownFeeTiers;

  constructor(IUniswapV3Factory _factory, uint8 _cardinalityPerMinute) {
    factory = _factory;
    cardinalityPerMinute = _cardinalityPerMinute;

    // Assign default fee tiers
    knownFeeTiers.push(300);
    knownFeeTiers.push(5000);
    knownFeeTiers.push(10000);
  }

  /// @inheritdoc IStaticOracle
  function supportedFeeTiers() external view override returns (uint24[] memory) {
    return knownFeeTiers;
  }

  /// @inheritdoc IStaticOracle
  function quoteAllAvailablePoolsWithTimePeriod(
    uint128 baseAmount,
    address baseToken,
    address quoteToken,
    uint32 period
  ) external view override returns (uint256 quoteAmount, address[] memory queriedPools) {
    queriedPools = _getQueryablePoolsForTiers(baseToken, quoteToken, period);
    quoteAmount = _quote(baseAmount, baseToken, quoteToken, queriedPools, period);
  }

  /// @inheritdoc IStaticOracle
  function quoteSpecificFeeTiersWithTimePeriod(
    uint128 baseAmount,
    address baseToken,
    address quoteToken,
    uint24[] calldata feeTiers,
    uint32 period
  ) external view override returns (uint256 quoteAmount, address[] memory queriedPools) {
    queriedPools = _getPoolsForTiers(baseToken, quoteToken, feeTiers);
    require(queriedPools.length == feeTiers.length, 'Given tier does not have pool');
    quoteAmount = _quote(baseAmount, baseToken, quoteToken, queriedPools, period);
  }

  /// @inheritdoc IStaticOracle
  function quoteSpecificPoolsWithTimePeriod(
    uint128 baseAmount,
    address baseToken,
    address quoteToken,
    address[] calldata pools,
    uint32 period
  ) external view override returns (uint256 quoteAmount) {
    return _quote(baseAmount, baseToken, quoteToken, pools, period);
  }

  /// @inheritdoc IStaticOracle
  function prepareAllAvailablePoolsWithTimePeriod(
    address tokenA,
    address tokenB,
    uint32 period
  ) external override returns (address[] memory preparedPools) {
    preparedPools = _getPoolsForTiers(tokenA, tokenB, knownFeeTiers);
    _prepare(preparedPools, period);
  }

  /// @inheritdoc IStaticOracle
  function prepareSpecificFeeTiersWithTimePeriod(
    address tokenA,
    address tokenB,
    uint24[] calldata feeTiers,
    uint32 period
  ) external override returns (address[] memory preparedPools) {
    preparedPools = _getPoolsForTiers(tokenA, tokenB, feeTiers);
    require(preparedPools.length == feeTiers.length, 'Given tier does not have pool');
    _prepare(preparedPools, period);
  }

  /// @inheritdoc IStaticOracle
  function prepareSpecificPoolsWithTimePeriod(address[] calldata pools, uint32 period) external override {
    _prepare(pools, period);
  }

  /// @inheritdoc IStaticOracle
  function addNewFeeTeer(uint24 feeTier) external override {
    require(factory.feeAmountTickSpacing(feeTier) != 0, 'Invalid fee tier');
    for (uint256 i; i < knownFeeTiers.length; i++) {
      require(knownFeeTiers[i] != feeTier, 'Tier already supported');
    }
    knownFeeTiers.push(feeTier);
  }

  function _prepare(address[] memory pools, uint32 period) internal {
    uint16 cardinality = uint16((period * cardinalityPerMinute) / 60) + 1; // We add 1 just to be on the safe side
    for (uint256 i; i < pools.length; i++) {
      IUniswapV3Pool(pools[i]).increaseObservationCardinalityNext(cardinality);
    }
  }

  function _quote(
    uint128 baseAmount,
    address baseToken,
    address quoteToken,
    address[] memory pools,
    uint32 period
  ) internal view returns (uint256 quoteAmount) {
    require(pools.length > 0, 'No defined pools');

    OracleLibrary.WeightedTickData[] memory tickData = new OracleLibrary.WeightedTickData[](pools.length);
    for (uint256 i; i < pools.length; i++) {
      (tickData[i].tick, tickData[i].weight) = period > 0
        ? OracleLibrary.consult(pools[i], period)
        : OracleLibrary.getBlockStartingTickAndLiquidity(pools[i]);
    }

    int24 weightedTick = tickData.length == 1 ? tickData[0].tick : OracleLibrary.getWeightedArithmeticMeanTick(tickData);
    return OracleLibrary.getQuoteAtTick(weightedTick, baseAmount, baseToken, quoteToken);
  }

  /// @notice Takes a pair and a time period, and returns all pools that could be queried for that period
  /// @param tokenA One of the pair's tokens
  /// @param tokenB The other of the pair's tokens
  /// @param period The period that we want to query for
  /// @return queryablePools All pools that can be queried
  function _getQueryablePoolsForTiers(
    address tokenA,
    address tokenB,
    uint32 period
  ) internal view returns (address[] memory) {
    address[] memory existingPools = _getPoolsForTiers(tokenA, tokenB, knownFeeTiers);
    // If period is 0, then just return all existing pools
    if (period == 0) return existingPools;

    address[] memory queryablePools = new address[](existingPools.length);
    uint256 validPools;
    for (uint256 i; i < existingPools.length; i++) {
      if (OracleLibrary.getOldestObservationSecondsAgo(existingPools[i]) >= period) {
        queryablePools[validPools++] = existingPools[i];
      }
    }

    return _copyValidElementsIntoNewArray(queryablePools, validPools);
  }

  /// @notice Takes a pair and some fee tiers, and returns all pools that match those tiers
  /// @param tokenA One of the pair's tokens
  /// @param tokenB The other of the pair's tokens
  /// @param feeTiers The fee tiers to consider when searching for the pair's pools
  /// @return pools The pools for the given pair and fee tiers
  function _getPoolsForTiers(
    address tokenA,
    address tokenB,
    uint24[] memory feeTiers
  ) internal view returns (address[] memory) {
    address[] memory pools = new address[](feeTiers.length);
    uint256 validPools;
    for (uint256 i; i < feeTiers.length; i++) {
      address pool = factory.getPool(tokenA, tokenB, feeTiers[i]);
      if (pool != address(0)) {
        pools[validPools++] = pool;
      }
    }

    return _copyValidElementsIntoNewArray(pools, validPools);
  }

  function _copyValidElementsIntoNewArray(address[] memory tempArray, uint256 amountOfValidElements)
    internal
    pure
    returns (address[] memory array)
  {
    // If all elements are valid, then just return the temp array
    if (tempArray.length == amountOfValidElements) return tempArray;

    // If not, then copy valid elements into new array
    array = new address[](amountOfValidElements);
    for (uint256 i; i < amountOfValidElements; i++) {
      array[i] = tempArray[i];
    }
  }
}
