// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.6;

// interfaces
import { ERC725Y } from "../../submodules/ERC725/implementations/contracts/ERC725/ERC725Y.sol";
import { IERC1271 } from "../../submodules/ERC725/implementations/contracts/IERC1271.sol";

// modules
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

// libraries
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { SafeMath } from "@openzeppelin/contracts/utils/math/SafeMath.sol";

/// @title Version 2.0 of the KeyManager (manage permissions when interacting with ERC725 Accounts)
/// @author Lukso's team (Fabian Vogelsteller, Jean Cavallera)
/// @dev all the permissions can be set on the ERC725 Account using `setData(...)` with the keys constants below
contract KeyManagerV2 is ERC165, IERC1271 {
    using ECDSA for bytes32;
    using SafeMath for uint256;

    ERC725Y public Account;
    mapping (address => uint256) internal _nonceStore;
    mapping (address => bool) internal _locks;

    bytes4 internal constant _INTERFACE_ID_ERC1271 = 0x1626ba7e;
    bytes4 internal constant _ERC1271FAILVALUE = 0xffffffff;

    // PERMISSION KEYS
    bytes8 internal constant SET_PERMISSIONS       = 0x4b80742d00000000; // AddressPermissions:<...>
    bytes12 internal constant KEY_PERMISSIONS      = 0x4b80742d0000000082ac0000; // AddressPermissions:Permissions:<address> --> bytes1
    bytes12 internal constant KEY_ALLOWEDADDRESSES = 0x4b80742d00000000c6dd0000; // AddressPermissions:AllowedAddresses:<address> --> address[]
    bytes12 internal constant KEY_ALLOWEDFUNCTIONS = 0x4b80742d000000008efe0000; // AddressPermissions:AllowedFunctions:<address> --> bytes4[]
    bytes12 internal constant KEY_ALLOWEDSTANDARDS = 0x4b80742d000000003efa0000; // AddressPermissions:AllowedStandards:<address> --> bytes4[]

    // PERMISSIONS VALUES
    bytes1 internal constant PERMISSION_CHANGEOWNER   = 0x01;   // 0000 0001
    bytes1 internal constant PERMISSION_CHANGEKEYS    = 0x02;   // 0000 0010
    bytes1 internal constant PERMISSION_SETDATA       = 0x04;   // 0000 0100
    bytes1 internal constant PERMISSION_CALL          = 0x08;   // 0000 1000
    bytes1 internal constant PERMISSION_DELEGATECALL  = 0x10;   // 0001 0000
    bytes1 internal constant PERMISSION_DEPLOY        = 0x20;   // 0010 0000
    bytes1 internal constant PERMISSION_TRANSFERVALUE = 0x40;   // 0100 0000
    bytes1 internal constant PERMISSION_SIGN          = 0x80;   // 1000 0000

    // selectors
    bytes4 internal constant SETDATA_SELECTOR = 0x7f23690c;
    bytes4 internal constant EXECUTE_SELECTOR = 0x44c028fe;
    bytes4 internal constant TRANSFEROWNERSHIP_SELECTOR = 0xf2fde38b;

    event Executed(uint256 indexed  _value, bytes _data);

    constructor(address _account) {
        // Set account
        Account = ERC725Y(_account);
    }

     /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        virtual override(ERC165) 
        returns (bool) 
    {
        return interfaceId == _INTERFACE_ID_ERC1271 
        || super.supportsInterface(interfaceId);
    }

    function getNonce(address _address) public view returns (uint256) {
        return _nonceStore[_address];
    }

    /**
    * @notice Checks if an owner signed `_data`.
    * ERC1271 interface.
    *
    * @param _hash hash of the data signed//Arbitrary length data signed on the behalf of address(this)
    * @param _signature owner's signature(s) of the data
    */
    function isValidSignature(bytes32 _hash, bytes memory _signature)
        override
        public
        pure
        returns (bytes4 magicValue)
    {
        address recoveredAddress = ECDSA.recover(_hash, _signature);

        // check if has permission to sign
        return (true)
            ? _INTERFACE_ID_ERC1271
            : _ERC1271FAILVALUE;
    }

    function execute(bytes calldata _data)
        external
        payable
        returns (bool success_)
    {
        _checkPermissions(msg.sender, _data);
        (success_, ) = address(Account).call{value: msg.value, gas: gasleft()}(_data);
        if (success_) emit Executed(msg.value, _data);
    }

    function executeRelayedCall(
        bytes calldata _data,
        address _signedFor,
        uint256 _nonce,
        bytes memory _signature
    )
        external
        payable
        returns (bool success_)
    {
        require(_signedFor == address(this), "KeyManager:_checkPermissionsRelayedCall: Message not signed for this keyManager");
    
        bytes memory blob = abi.encodePacked(
            address(this), // needs to be signed for this keyManager
            _data,
            _nonce
        );

        // recover the signer
        address from = keccak256(blob).toEthSignedMessageHash().recover(_signature);
        // require(hasRole(EXECUTOR_ROLE, from), 'Only executors are allowed');
        require(_nonceStore[from] == _nonce, "KeyManager:_checkPermissionsRelayedCall: Incorrect nonce");

        // increase the nonce
        _nonceStore[from] = _nonceStore[from].add(1);

        _checkPermissions(from, _data);

        (success_, ) = address(Account).call{value: 0, gas: gasleft()}(_data);
        if (success_) emit Executed(msg.value, _data);
    }

    function _checkPermissions(address _address, bytes calldata _data) internal view {
        bytes1 userPermissions = _getUserPermissions(_address);
        // bytes4 ERC725Selector = bytes4(_data[68:72]);
        bytes4 ERC725Selector = bytes4(_data[:4]);
        
        if (ERC725Selector == SETDATA_SELECTOR) {
            // bytes8 setDataKey = bytes8(_data[72:80]);
            bytes8 setDataKey = bytes8(_data[4:12]);

            if (setDataKey == SET_PERMISSIONS) {
                require(_isAllowed(PERMISSION_CHANGEKEYS, userPermissions), "KeyManager:_checkPermissions: Not authorized to change keys");
            } else {
                require(_isAllowed(PERMISSION_SETDATA, userPermissions), "KeyManager:_checkPermissions: Not authorized to setData");
            }
        } else if (ERC725Selector == EXECUTE_SELECTOR) {
            // uint8 operationType = uint8(bytes1(_data[103:104]));
            uint8 operationType = uint8(bytes1(_data[35:36]));
            // address recipient = address(bytes20(_data[115:135]));
            address recipient = address(bytes20(_data[48:68]));
            // uint value = uint8(bytes1(_data[136:137]));
            uint value = uint(bytes32(_data[68:100]));
            // 1st 32 bytes = memory location
            // 2nd 32 bytes = bytes array length
            // remaining = actual bytes array
            // bytes4 functionSelector = bytes4(_data[232:236]);

            // Check for CALL, DELEGATECALL or DEPLOY
            require(operationType < 4, 'KeyManager:_checkPermissions: Invalid operation type');

            bytes1 permission;
            assembly {
                switch operationType
                case 0 { permission := PERMISSION_CALL } 
                case 1 { permission := PERMISSION_DELEGATECALL }
                case 2 { permission := PERMISSION_DEPLOY }  // CREATE2
                case 3 { permission := PERMISSION_DEPLOY }  // CREATE
            }
            bool operationAllowed = _isAllowed(permission, userPermissions);

            if (!operationAllowed && permission == PERMISSION_CALL) revert('KeyManager:_checkPermissions: not authorized to perform CALL');
            if (!operationAllowed && permission == PERMISSION_DELEGATECALL) revert('KeyManager:_checkPermissions: not authorized to perform DELEGATECALL');
            if (!operationAllowed && permission == PERMISSION_DEPLOY) revert('KeyManager:_checkPermissions: not authorized to perform DEPLOY');
        
            // Check for authorized addresses
            require(_isAllowedAddress(_address, recipient), 'KeyManager:_checkPermissions: Not authorized to interact with this address');
        
            // Check for value
            if (value > 0) {
                require(_isAllowed(PERMISSION_TRANSFERVALUE, userPermissions), 'KeyManager:_checkPermissions: Not authorized to transfer ethers');
            }

            // Check for functions
            if (_data.length > 164) {
                bytes4 functionSelector = bytes4(_data[164:168]);
                if (functionSelector != 0x00000000) {
                    require(_isAllowedFunction(_address, functionSelector), 'KeyManager:_checkPermissions: Not authorised to run this function');
                }
            }
        } else if (ERC725Selector == TRANSFEROWNERSHIP_SELECTOR) {
            require(_isAllowed(PERMISSION_CHANGEOWNER, userPermissions), 'KeyManager:_checkPermissions: Not authorized to transfer ownership');
        } else {
            revert('KeyManager:_checkPermissions: unknown function selector from ERC725 account');
        }
    }

    function _getUserPermissions(address _address) internal view returns (bytes1) {
        bytes32 permissionKey;
        bytes memory computedKey = abi.encodePacked(KEY_PERMISSIONS, _address);

        assembly { 
            permissionKey := mload(add(computedKey, 32))
        }

        bytes1 storedPermission;
        bytes memory fetchResult = Account.getData(permissionKey);

        if (fetchResult.length == 0) revert("KeyManager:_getUserPermissions: no permissions set for this user / caller");

        assembly {
            storedPermission := mload(add(fetchResult, 32))
        }

        return storedPermission;
    }

    function _getAllowedAddresses(address _sender) internal view returns (bytes memory) {
        bytes memory allowedAddressesKeyComputed = abi.encodePacked(KEY_ALLOWEDADDRESSES, _sender);
        bytes32 allowedAddressesKey;
        assembly {
            allowedAddressesKey := mload(add(allowedAddressesKeyComputed, 32))
        }
        return Account.getData(allowedAddressesKey);
    }

    function _getAllowedFunctions(address _sender) internal view returns (bytes memory) {
        bytes memory allowedAddressesKeyComputed = abi.encodePacked(KEY_ALLOWEDFUNCTIONS, _sender);
        bytes32 allowedFunctionsKey;
        assembly {
            allowedFunctionsKey := mload(add(allowedAddressesKeyComputed, 32))
        }
        return Account.getData(allowedFunctionsKey);
    }

    function _isAllowedAddress(address _sender, address _recipient) internal view returns (bool) {
        bytes memory allowedAddresses = _getAllowedAddresses(_sender);

        if (allowedAddresses.length == 0) {
            return true;
        } else {
            address[] memory allowedAddressesList = abi.decode(allowedAddresses, (address[]));
            if (allowedAddressesList.length == 0) {
                return true;
            } else {
                for (uint ii = 0; ii <= allowedAddressesList.length - 1; ii++) {
                    if (_recipient == allowedAddressesList[ii]) return true;
                }
                return false;
            }
        }
    }

    function _isAllowedFunction(address _sender, bytes4 _function) internal view returns (bool) {
        bytes memory allowedFunctions = _getAllowedFunctions(_sender);

        if (allowedFunctions.length == 0) {
            return true;
        } else {
            bytes4[] memory allowedFunctionsList = abi.decode(allowedFunctions, (bytes4[]));
            if (allowedFunctionsList.length == 0) {
                return true;
            } else {
                for (uint ii  = 0; ii <= allowedFunctionsList.length - 1; ii++) {
                    if (_function == allowedFunctionsList[ii]) return true;
                }
                return false;
            }
        }   
    }

    function _isAllowed(bytes1 _permission, bytes1 _addressPermission) internal pure returns (bool) {
        uint8 resultCheck = uint8(_permission) & uint8(_addressPermission);

        if (resultCheck == uint8(_permission)) { // pass
            return true;
        } else if (resultCheck == 0) {  // fail 
            // return (false, 0x00);
            return false;
        } else {    // refer
            // in this case, the user has part of the permissions, but not all of them
            // XOR previous result against permission required to find missing permissions
            // See: LSP6
            // bytes1 missingPermission = resultCheck ^ _permission;
            // return (false, missingPermission);
            // return 
            return false;
        }
    }


}