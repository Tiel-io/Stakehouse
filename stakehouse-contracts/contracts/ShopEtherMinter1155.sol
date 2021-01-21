// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "hardhat/console.sol";

import "./FeeOwner.sol";
import "./Fee1155.sol";

/**
  @title A simple Shop contract for selling ERC-1155s for Ether via direct
         minting.
  @author Tim Clancy

  This contract is a limited subset of the Shop1155 contract designed to mint
  items directly to the user upon purchase.
*/
contract ShopEtherMinter1155 is Ownable, ERC1155Holder {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  /// A version number for this Shop contract's interface.
  uint256 public version = 1;

  /// @dev A mask for isolating an item's group ID.
  uint256 constant GROUP_MASK = uint256(uint128(~0)) << 128;

  /// A user-specified Fee1155 contract to support selling items from.
  Fee1155 public item;

  /// A user-specified FeeOwner to receive a portion of Shop earnings.
  FeeOwner public feeOwner;

  /// The Shop's inventory of items for sale as well as price-per-item group.
  mapping (uint256 => uint256) public prices;

  /**
    Construct a new Shop by providing it a FeeOwner.

    @param _item The address of the Fee1155 item that will be minting sales.
    @param _feeOwner The address of the FeeOwner due a portion of Shop earnings.
  */
  constructor(Fee1155 _item, FeeOwner _feeOwner) public {
    item = _item;
    feeOwner = _feeOwner;
  }

  /**
    Allows the Shop owner to list a new set of NFT items for sale.
  */
  function listItems(uint256[] calldata _groupIds, uint256[] calldata _prices) public onlyOwner {
    require(_groupIds.length > 0,
      "You must list at least one item.");
    require(_groupIds.length == _prices.length,
      "Items length cannot be mismatched with prices length.");

    // Iterate through every specified item group to list items.
    for (uint256 i = 0; i < _groupIds.length; i++) {
      uint256 groupId = _groupIds[i];
      uint256 price = _prices[i];
      prices[groupId] = price;
    }
  }

  /**
    Allows the Shop owner to remove items.
  */
  function removeItems(uint256[] calldata _groupIds) public onlyOwner {
    require(_groupIds.length > 0,
      "You must remove at least one item.");

    // Iterate through every specified item group to remove items.
    for (uint256 i = 0; i < _groupIds.length; i++) {
      uint256 groupId = _groupIds[i];
      prices[groupId] = 0;
    }
  }

  /**
    Allows any user to purchase items from this Shop.
  */
  function purchaseItems(uint256[] calldata _itemIds) public payable {
    require(_itemIds.length > 0,
      "You must purchase at least one item.");

    // Iterate through every specified item to list items.
    uint256 feePercent = feeOwner.fee();
    uint256 itemRoyaltyPercent = item.feeOwner().fee();
    for (uint256 i = 0; i < _itemIds.length; i++) {
      uint256 itemId = _itemIds[i];
      uint256 groupId = itemId & GROUP_MASK;
      uint256 price = prices[groupId];
      require(price > 0,
        "You cannot purchase an item that is not listed.");

      // Split fees for this purchase.
      uint256 feeValue = price.mul(feePercent).div(100000);
      uint256 royaltyValue = price.mul(itemRoyaltyPercent).div(100000);
      payable(feeOwner.owner()).transfer(feeValue);
      payable(item.feeOwner().owner()).transfer(royaltyValue);
      payable(owner()).transfer(price.sub(feeValue).sub(royaltyValue));

      item.mint(msg.sender, itemId, 1, "");
    }
  }
}
