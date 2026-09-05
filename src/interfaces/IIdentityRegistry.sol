// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IIdentityRegistry {
    function isVerified(address wallet) external view returns (bool);
    function identity(address wallet) external view returns (address);
    function investorCountry(address wallet) external view returns (uint16);
    function registerIdentity(address wallet, address investorIdentity, uint16 country) external;
    function deleteIdentity(address wallet) external;
}
