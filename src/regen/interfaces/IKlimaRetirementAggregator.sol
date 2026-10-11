// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Klima Retirement Aggregator (EIP-2535 diamond; Base 0xda0a793d7c32ab80bcdab7f8c725c96db22464f4, RetireFacet
///      0xcc4f3a842de8e31e71d40ccb5d3ac4cd03eaabd9). Verbatim from the Sourcify exact-match source of the facet
///      (`src/interfaces/IRetireFacet.sol`, `src/libraries/LibRetire.sol`, `src/interfaces/IKlimaProtocol.sol`),
///      read 2026-10-08.
struct RetireDetails {
    address retiringAddress;
    string retiringEntityString;
    address beneficiaryAddress;
    string beneficiaryString;
    string retirementMessage;
    string beneficiaryLocation;
    string consumptionCountryCode;
    uint256 consumptionPeriodStart;
    uint256 consumptionPeriodEnd;
}

struct DiscountedForwardBalanceContext {
    uint256 currentMidnightIndex;
    uint256 amountUsedForSwapQuote;
    uint256 discountedForwardBalanceForCurrentMidnightIndex;
}

struct UpdateLiquidSupplyRateLimiterParams {
    uint256 preTxnLiquidSupply;
}

interface IKlimaRetirementAggregator {
    /// @notice Tonnes a budget of `inputTokenAmount` (kVCM or USDC) retires from `creditToken` in `carbonClass`.
    function quoteRetireCreditForInputTokenInViaKlima(
        address creditToken,
        uint256 tokenId,
        uint256 inputTokenAmount,
        address inputTokenAddress,
        address carbonClass,
        uint256 couponTonnes
    )
        external
        view
        returns (
            uint256 tonnes,
            uint256 tokenAmount,
            uint256 retirementPrice,
            DiscountedForwardBalanceContext memory discountedForwardBalanceContext,
            UpdateLiquidSupplyRateLimiterParams memory updateLiquidSupplyRateLimiterParams
        );

    /// @notice Price in the input token of retiring `amount` tonnes.
    function quoteRetireCreditViaKlima(
        address creditToken,
        uint256 tokenId,
        uint256 amount,
        address inputTokenAddress,
        address carbonClass,
        uint256 couponTonnes
    )
        external
        view
        returns (
            uint256 tonnes,
            uint256 retirementPrice,
            DiscountedForwardBalanceContext memory discountedForwardBalanceContext,
            UpdateLiquidSupplyRateLimiterParams memory updateLiquidSupplyRateLimiterParams
        );

    /// @dev USDC: the aggregator pulls `maxInputTokenIn` worth of USDC from the caller (approve the aggregator), swaps
    ///      it to kVCM on Aerodrome and reverts `SlippageExceeded(required, maxAllowed)` if more would be needed.
    ///      kVCM: the Klima Protocol (AAM) pulls from the caller instead (approve the AAM).
    function retireCreditViaKlima(
        address creditToken,
        uint256 tokenId,
        uint256 batchId,
        uint256 amount,
        address inputTokenAddress,
        address carbonClass,
        uint256 maxInputTokenIn,
        uint256 couponTonnes,
        RetireDetails memory details
    ) external;
}
