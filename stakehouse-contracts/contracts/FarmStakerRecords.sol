// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./Token.sol";
import "./Staker.sol";

/**
  @title A basic smart contract for tracking the ownership of Stakehouse Stakers.
  @author Tim Clancy

  This is the governing registry of all Stakehouse Staker assets.
*/
contract FarmStakerRecords is Ownable {

  /// A version number for this record contract's interface.
  uint256 public version = 1;

  /// A mapping for an array of all Stakers deployed by a particular address.
  mapping (address => address[]) public farmRecords;

  /// An event for tracking the creation of a new Staker.
  event FarmCreated(address indexed farmAddress, address indexed creator);

  /**
    Create a Staker on behalf of the owner calling this function. The Staker
    supports immediate specification of the emission schedule and pool strength.

    @param _name The name of the Staker to create.
    @param _token The Token to reward stakers in the Staker with.
    @param _strength The relative strength of the new, first Token pool.
    @param _blockNumbers An array of block numbers to key associated rates to.
    @param _rates An array of emission rates for the corresponding blocks.
  */
  function createFarm(string calldata _name, IERC20 _token, uint256 _strength, uint256[] calldata _blockNumbers, uint256[] calldata _rates) external returns (Staker) {
    Staker newStaker = new Staker(_name, _token);

    // Establish the emissions schedule and add the token pool.
    newStaker.addEmissions(_blockNumbers, _rates);
    newStaker.addPool(_token, _strength);

    // Transfer ownership of the new Staker to the user then store a reference.
    newStaker.transferOwnership(msg.sender);
    address stakerAddress = address(newStaker);
    farmRecords[msg.sender].push(stakerAddress);
    emit FarmCreated(stakerAddress, msg.sender);
    return newStaker;
  }

  /**
    Allow a user to add an existing Staker contract to the registry.

    @param _farmAddress The address of the Staker contract to add for this user.
  */
  function addFarm(address _farmAddress) external {
    farmRecords[msg.sender].push(_farmAddress);
  }

  /**
    Get the number of entries in the Staker records mapping for the given user.

    @return The number of Stakers added for a given address.
  */
  function getFarmCount(address _user) external view returns (uint256) {
    return farmRecords[_user].length;
  }
}
