pragma solidity ^0.5.8;

import "./Governance.sol";
import "./Franklin.sol";
import "./BlsVerifier.sol";
import "./SafeMath.sol";
import "./BlsOperations.sol";

/// @title Lending Token Contract
/// @notice Inner logic for LendingEther and LendingErc20 token contracts
/// @author Matter Labs
contract LendingToken is BlsVerifier {
    
    using SafeMath for uint256;

    /// @notice Possible price change coeff on Compound
    uint256 constant possiblePriceRisingCoeff = 110/100;

    /// @notice Multiplier is used in calculation of borrowing interest rate
    uint256 constant MULTIPLIER = 45;

    /// @notice Base rate is used in calculation of borrowing interest rate
    uint256 constant BASE_RATE = 5;

    /// @notice Spread represents the economic profit of the protocol
    uint256 constant SPREAD = 10;

    /// @notice Owner of the contract (Matter Labs)
    address internal owner;

    /// @notice Matter token contract address
    uint16 internal matterToken;

    /// @notice blsVerifier contract
    BlsVerifier internal blsVerifier;

    /// @notice Governance contract
    Governance internal governance;

    /// @notice Rollup contract
    Franklin internal rollup;

    /// @notice last verified Fraklin block
    uint256 internal lastVerifiedBlock;

    /// @notice total funds supply on contract
    uint256 internal totalSupply;

    /// @notice total funds borrowed on contract
    uint256 internal totalBorrowed;

    /// @notice Validators addresses list
    mapping(uint32 => address) internal validators;
    /// @notice Each validators' info
    mapping(address => ValidatorInfo) internal validatorsInfo;
    /// @notice validators count
    uint32 internal validatorsCount;

    /// @dev Possible exit order states
    enum ExitOrderState {
        None,
        Deffered,
        Fulfilled
    }

    /// @notice Swift Exits hashes (withdraw op hash) by Rollup block number
    mapping(uint32 => mapping(uint32 => uint256)) internal exitOrdersHashes;
    /// @notice Swift Exits in blocks count
    mapping(uint32 => uint32) internal exitOrdersCount;
    /// @notice Swift Exits by its hash (withdraw op hash)
    mapping(uint256 => ExitOrder) internal exitOrders;

    /// @notice Borrow orders by Swift Exits hashes (withdraw op hash)
    mapping(uint256 => mapping(uint32 => BorrowOrder)) internal BorrowOrders;
    /// @notice BOrrow orders in Swift Exits count
    mapping(uint256 => uint32) internal borrowOrdersCount;

    /// @notice Container for information about validator
    /// @member exists Flag for validator existance in current lending process
    /// @member pubkey Validators' pubkey
    /// @member supply Validators' supplied funds
    struct ValidatorInfo {
        bool exists;
        BlsOperations.G2Point pubkey;
        uint256 supply;
    }

    /// @notice Container for information about borrow order
    /// @member borrowed This orders' borrow
    /// @member fee This orders' fee
    /// @member borrowed Borrow orders' recipient (validator)
    struct BorrowOrder {
        uint256 borrowed;
        uint256 fee;
        address validator;
    }

    /// @notice Container for information about Swift Exit Order
    /// @member status Order status
    /// @member withdrawOpOffset Withdraw operation offset in block
    /// @member tokenId Order token id
    /// @member tokenAmount Order token amount
    /// @member recipient Recipient address
    struct ExitOrder {
        ExitOrderState status;
        uint64 withdrawOpOffset;
        uint16 tokenId;
        uint256 tokenAmount;
        address recipient;
    }

    /// @notice Emitted when a new swift exit order occurs
    event UpdatedExitOrder(
        uint32 blockNumber,
        uint32 orderNumber,
        uint256 expectedAmountToSupply
    );

    /// @notice Construct swift exits contract
    /// @param _matterTokenId The id of Matter token
    /// @param _governanceAddress The address of Governance contract
    /// @param _rollupAddress The address of Rollup contract
    /// @param _blsVerifierAddress The address of Bls Verifier contract
    /// @param _owner The address of this contracts owner (Matter Labs)
    constructor(
        uint16 _matterTokenId,
        address _governanceAddress,
        address _rollupAddress,
        address _blsVerifierAddress,
        address _owner
    ) public {
        governance = Governance(_governanceAddress);
        rollup = Franklin(_rollupAddress);
        lastVerifiedBlock = rollup.totalBlocksVerified;
        blsVerifier = BlsVerifier(_blsVerifierAddress);
        matterToken = _matterTokenId;
        owner = _owner;
    }

    /// @notice Fallback function always reverts
    function() external {
        revert("Cant accept ether through fallback function");
    }

    /// @notice Transfers specified amount of ERC20 token into contract
    /// @param _from Sender address
    /// @param _token ERC20 token id
    /// @param _amount Amount in ERC20 tokens
    function transferInERC20(address _from, uint16 _tokenId, uint256 _amount) internal {
        address tokenAddr = governance.tokenAddresses(_tokenId);
        require(
            IERC20(tokenAddr).transferFrom(_from, address(this), _amount),
            "sst011"
        ); // sst011 - token transfer in failed
    }

    /// @notice Transfers specified amount of Ether or ERC20 token to external address
    /// @dev If token id == 0 -> transfers ether
    /// @param _to Receiver address
    /// @param _tokenId ERC20 token id
    /// @param _amount Amount in ERC20 tokens
    function transferOut(address _to, uint16 _tokenId, uint256 _amount) internal {
        if (_tokenId == 0) {
            _to.transfer(_amount);
        } else {
            address tokenAddr = governance.tokenAddresses(_tokenId);
            require(
                IERC20(tokenAddr).transfer(_to, _amount),
                "lctt11"
            ); // lctt11 - token transfer out failed
        }
    }
    
    /// @notice Adds new validator
    /// @dev Only owner can add new validator
    /// @param _addr Validator address
    /// @param _pbkxx Validator pubkey xx
    /// @param _pbkxy Validator pubkey xy
    /// @param _pbkyx Validator pubkey yx
    /// @param _pbkyy Validator pubkey yy
    function addValidator(
        address _addr,
        uint256 _pbkxx,
        uint256 _pbkxy,
        uint256 _pbkyx,
        uint256 _pbkyy
    ) external {
        requireOwner();
        require(
            !validatorsInfo[_addr].exists,
            "osar11"
        ); // osar11 - operator exists
        validatorsInfo[_addr].exists = true;
        validatorsInfo[_addr].pubkey = BlsOperations.G2Point({
                x: [
                    _pbkxx,
                    _pbkxy
                ],
                y: [
                    _pbkyx,
                    _pbkyy
                ]
        });
        validatorsCount++;
    }

    /// @notice Gets allowed withdraw amount for validator
    /// @dev Requires validators' existance
    /// @param _addr Validator address
    function getAllowedWithdrawAmount(address _addr) public returns (uint256) {
        if (totalSupply-totalBorrowed >= validatorsInfo[_addr].supply) {
            return validatorsInfo[_addr].supply;
        } else {
            return totalSupply-totalBorrowed;
        }
    }

    /// @notice Withdraws specified amount from validators supply
    /// @dev Requires validators' existance and allowed amount is >= specified amount, which should not be equal to 0
    /// @param _amount Specified amount
    function withdrawForValidator(uint256 _amount) external {
        require(
            getAllowedWithdrawAmount(msg.sender) >= _amount,
            "osar11"
        ); // osar11 - wrong amount
        immediateWithdraw(amount);
    }

    /// @notice Withdraws possible amount from validators supply
    /// @dev Requires validators' existance and allowed amount > 0
    function withdrawPossibleForValidator() external {
        uint256 amount = getAllowedWithdrawAmount(msg.sender);
        immediateWithdraw(amount);
    }

    /// @notice The specified amount of funds will be withdrawn from validators supply
    /// @param _amount Specified amount
    function immediateWithdraw(uint256 _amount) internal {
        require(
            _amount > 0,
            "osar11"
        ); // osar11 - wrong amount
        transferOut(msg.sender, matterToken, _amount);
        totalSupply -= _amount;
        validatorsInfo[msg.sender].supply -= _amount;
    }

    /// @notice Removes validator for current processing list
    /// @dev Requires owner as sender and validators' existance
    /// @param _addr Validator address
    function removeValidator(
        address _addr
    ) external {
        requireOwner();
        require(
            validatorsInfo[_addr].exists,
            "osar11"
        ); // osar11 - operator does not exists

        validatorsInfo[_addr].exists = false;

        bool found = false;
        for (uint32 i = 0; i < validatorsCount-2; i++){
            if (found || validators[i] == _addr) {
                found = true;
                validators[i] = validators[i+1];
            }
        }
        delete validators[validatorsCount-1];
        validatorsCount--;
    }

    /// @notice Supplies specified amount of tokens from validator
    /// @dev Calls transferIn function of specified token and fulfillDefferedWithdrawOrders to fulfill deffered withdraw orders
    /// @param _addr Validator account address
    /// @param _amount Token amount
    function supplyValidator(address _addr, uint256 _amount) public {
        require(
            validatorsInfo[_addr].exists,
            "ossy11"
        ); // ossy11 - operator does not exists
        transferInERC20(_addr, matterToken, _amount);
        totalSupply = _addr.add(_amount);
        validatorsInfo[_addr] += _amount;
    }

    /// @notice Returns validators pubkeys for specified validators addresses
    /// @param _validators Validators addresses
    function getValidatorsPubkeys(address[] memory _validators) internal returns (BlsOperations.G2Point[] memory pubkeys) {
        for (uint32 i = 0; i < _validators.length; i++) {
            pubkeys[i] = validatorsInfo[_validators[i]].pubkey;
        }
        return pubkeys;
    }

    /// @notice Adds new swift exit
    /// @dev Only owner can send this order, validates validators signature, requires that order must be new (status must be None)
    /// @param _blockNumber Rollup block number
    /// @param _withdrawOpOffset Withdraw operation offset in block
    /// @param _withdrawOpHash Withdraw operation hash
    /// @param _tokenId Token id
    /// @param _tokenAmount Token amount
    /// @param _recipient Swift exit recipient
    /// @param _aggrSignatureX Aggregated validators signature x
    /// @param _aggrSignatureY Aggregated validators signature y
    /// @param _validators Validators addresses list
    function addSwiftExit(
        uint32 _blockNumber,
        uint64 _withdrawOpOffset,
        uint256 _withdrawOpHash,
        uint16 _tokenId,
        uint256 _tokenAmount,
        address _recipient,
        uint256 _aggrSignatureX,
        uint256 _aggrSignatureY,
        address[] calldata _validators
    ) external {
        requireOwner();
        require(
            blsVerifier.verifyBlsSignature(
                G1Point(_aggrSignatureX, _aggrSignatureY),
                getValidatorsPubkeys(_validators)
            ),
            "ltct11"
        ); // "ltwl11" - wrong signature
        require(
            exitOrders[_withdrawOpHash].status == ExitOrderState.None,
            "ltct11"
        ); // "ltwl11" - request exists
        
        if (_blockNumber <= _lastVerifiedBlock) {
            // If block is already verified - try to send requested funds to recipient on rollup contract
            rollup.trySwiftExitWithdraw(
                _blockNumber,
                _withdrawOpOffset,
                _withdrawOpHash
            );
        } else {
            // Get amount to borrow
            (uint256 amountForFees, uint256 amountToBorrow) = getAmountNeeded(_tokenId, _tokenAmount);

            // Create Exit orer
            ExitOrder order = ExitOrder(
                ExitOrderState.None,
                _withdrawOpOffset,
                _tokenId,
                0,
                _recipient
            );
            exitOrdersHashes[_blockNumber][exitOrdersCount[_blockNumber]] = _withdrawOpHash;
            exitOrders[_withdrawOpHash] = order;
            exitOrdersCount[_blockNumber]++;

            if (amountToBorrow <= (totalSupply - totalBorrowed)) {
                // If amount to borrow <= borrowable amount - immediate swift exit
                immediateSwiftExit(_blockNumber, _withdrawOpHash, amountToBorrow, amountForFees);
            } else {
                // If amount to borrow > borrowable amount - deffered swift exit order
                exitOrders[_withdrawOpHash].status = ExitOrderState.Deffered;
                emit UpdatedExitOrder(
                    _blockNumber,
                    _withdrawOpHash,
                    (amountToBorrow * possiblePriceRisingCoeff) - totalSupply + totalBorrowed
                );
            }
        }
    }

    /// @notice Supplies validators balance and immediatly fulfills swift exit order if possible
    /// @dev Requires that order must be deffered (status must be Deffered) and block must be unverified
    /// @param _blockNumber Rollup block number
    /// @param _withdrawOpHash Withdraw operation hash
    /// @param _sendingAmount Sending amount
    function supplyAndFulfillSwiftExitOrder(
        uint32 _blockNumber,
        uint32 _withdrawOpHash,
        uint256 _sendingAmount
    ) external {
        require(
            _blockNumber > lastVerifiedBlock,
            "ltfl12"
        ); // "ltfl12" - block is already verified
        require(
            exitOrders[_withdrawOpHash].status == ExitOrderState.Deffered,
            "ltfl12"
        ); // "ltfl12" - not deffered

        supplyValidator(msg.sender, _sendingAmount);
        
        ExitOrder order = exitOrders[_withdrawOpHash];

        uint256 updatedAmount = 0;
        (uint256 amountToBorrow, uint256 amountForFees) = getAmountNeeded(order.tokenId, order.tokenAmount);
        if (amountToBorrow <= (totalSupply - totalBorrowed)) {
            // If amount to borrow <= borrowable amount - immediate swift exit
            immediateSwiftExit(_blockNumber, _withdrawOpHash, amountToBorrow, amountForFees);
        } else {
            // If amount to borrow > borrowable amount - emit update deffered swift exit order event
            updatedAmount = (amountToBorrow * possiblePriceRisingCoeff) - totalSupply + totalBorrowed;
        }
        emit UpdatedExitOrder(
            _blockNumber,
            _withdrawOpHash,
            updatedAmount
        );
    }

    /// @notice Processes immediatly swift exit
    /// @dev Creates fee orders, exhanges tokens with compound, transfers token to recepient and creades swift order on rollup contract
    /// @param _blockNumber Rollup block number
    /// @param _withdrawOpHash Withdraw operation hash
    /// @param _amountToBorrow Amount to borrow from validators
    /// @param _amountForFees Amount to calculate fees for validators
    function immediateSwiftExit(
        uint32 _blockNumber,
        uint256 _withdrawOpHash,
        uint256 _amountToBorrow,
        uint256 _amountForFees
    ) internal {
        ExitOrder order = exitOrders[_withdrawOpHash];

        createBorrowOrders(_withdrawOpHash, _amountToBorrow, _amountForFees);

        uint256 tokenAmountToWithdraw = exchangeWithCompound(order.tokenId, _amountToBorrow);

        transferOut(order.receiver, tokenAddr, tokenAmountToWithdraw);

        rollup.orderSwiftExit(_blockNumber, order.withdrawOpOffset, _withdrawOpHash);

        exitOrders[_withdrawOpHash].tokenAmount = tokenAmountToWithdraw;
        exitOrders[_withdrawOpHash].status = ExitOrderState.Fulfilled;
        totalBorrowed += _amountToBorrow;
    }

    function exchangeWithCompound(
        uint16 _tokenId,
        uint256 _amountToExchange
    ) internal returns (uint256 tokenAmount) {
        address tokenAddress = governance.tokenAddresses(_tokenId);
        // register token on compount if needed
        // exchange possible value
    }

    function getAmountNeeded(
        uint16 _tokenId,
        uint256 _tokenAmount
    ) internal returns (uint256 amountToBorrow, uint256 amountForFees) {
        address tokenAddress = governance.tokenAddresses(_tokenId);
        // get token rate and calculate fees its amount
        // get amount of supply for complete exchange for this token amount
        // multiply by 3 to get complete amount to possible punishment
    }

    function createBorrowOrders(
        uint256 _withdrawOpHash,
        uint256 _amountToBorrow,
        uint256 _amountForFees
    ) internal {
        (uint256 bir, uint256 sir) = getCurrentInterestRates();

        (uint256 borrowerFee, uint256 validatorsFees, uint256 ownerFee) = calculateFees(_amountForFees, bir, sir);

        for (uint32 i = 0; i <= validatorCount; i++) {
            uint32 currentBorrowOrdersCount = borrowOrdersCount[_withdrawOpHash];
            BorrowOrders[_withdrawOpHash][currentBorrowOrdersCount] = BorrowOrder({
                borrowed: _amountToBorrow * (validatorsInfo[validators[i]].supply / totalSupply),
                fee: validatorsFees * (validatorsInfo[validators[i]].supply / totalSupply),
                validator: validators[i]
            });
            borrowOrdersCount[_withdrawOpHash]++;
        }
        uint32 currentBorrowOrdersCount = borrowOrdersCount[_withdrawOpHash];
        BorrowOrders[_withdrawOpHash][currentBorrowOrdersCount] = BorrowOrder({
            borrowed: _amountToBorrow * (validatorsInfo[owner].supply / totalSupply),
            fee: ownerFee + validatorsFees * (validatorsInfo[owner].supply / totalSupply),
            validator: owner
        });
        borrowOrdersCount[_withdrawOpHash]++;
    }

    function calculateFees(
        uint256 _amount,
        uint256 _borrowingInterestRate,
        uint256 _supplyInterestRate
    ) internal pure returns (uint256 borrowerFee, uint256 validatorsFees, uint256 ownerFee) {
        borrowerFee = bir * _amount;
        validatorsFees = borrowerFee * sir;
        ownerFee = borrowerFee - validatorsFees;
    }

    function getCurrentInterestRates() public pure returns (uint256 _borrowing, uint256 _supply) {
        uint256 u = totalBorrowed / (totalSupply + totalBorrowed);
        _borrowing = MULTIPLIER * u + BASE_RATE;
        _supply = _borrowing * u * (1 - SPREAD);
    }

    /// @notice Called by Rollup contract when a new block is verified. Fulfills swift orders process
    /// @dev Requires Rollup contract as caller. Repays for compound, consummate fees, fulfills deffered orders, punishes for failed exits
    /// @param _blockNumber The number of verified block
    /// @param _succeededHashes The succeeds exists hashes list
    /// @param _failedHashes The failed exists hashes list
    function newVerifiedBlock(
        uint32 _blockNumber,
        address[] calldata _validators,
        uint256[] calldata _succeededHashes,
        uint256[] calldata _failedHashes,
        address[] calldata _tokenAddresses,
        uint256[] calldata _tokenAmounts
    ) external payable {
        requireRollup();
        require(
            _tokenAddresses.length == _tokenAmounts.length,
            "ltfl12"
        ); // "ltfl12" - not deffered
        for (uint i = 0; i < token.length; i++) {
            transferInERC20(msg.sender, _tokenAddresses[i], _tokenAmounts[i]);
        }
        lastVerifiedBlock = _blockNumber;
        repayCompoundSucceded(_succeededHashes);
        fulfillSuccededOrders(_succeededHashes);
        punishForFailedOrders(_failedHashes, _validators);
        fulfillDefferedExitOrders(_blockNumber);
    }

    function repayCompoundSucceded(uint256[] memory _succeededHashes) internal {
        for (uint32 i = 0; i < _succeededHashes.length; i++) {
            ExitOrder order = exitOrders[_succeededHashes[i]];
            // repay compound
        }
    }

    function fulfillSuccededOrders(uint256[] memory _succeededHashes) internal {
        for (uint32 i = 0; i < _succeededHashes.length; i++) {
            for (uint32 k = 0; k < borrowOrdersCount[_succeededHashes[i]]; k++) {
                BorrowOrder order = BorrowOrders[_succeededHashes[i]][k];
                validatorsInfo[order.validator].supply += order.fee;
                totalSupply += order.fee;
                totalBorrowed -= order.borrowed;
            }
        }
    }

    function fulfillDefferedExitOrders(uint32 _blockNumber) internal {
        for (uint32 i = 0; i < exitOrdersCount[_blockNumber]; i++) {
            ExitOrder order = exitOrders[exitOrdersHashes[i]];
            if (order.status == ExitOrderState.Deffered) {
                rollup.trySwiftExitWithdraw(
                    _blockNumber,
                    order.withdrawOpOffset,
                    order.withdrawOpHash
                );
            }
        }
    }

    function punishForFailed(uint256[] memory _failedHashes) internal {
         for (uint32 i = 0; i < _failedHashes.length; i++) {
            for (uint32 k = 0; k < borrowOrdersCount[_failedHashes[i]]; k++) {
                BorrowOrder order = BorrowOrders[_succeededHashes[i]][k];
                validatorsInfo[order.validator].supply -= borrowed;
                totalSupply -= order.borrowed;
                totalBorrowed -= order.borrowed;
            }
        }
    }

    // function getIntersection(address[] memory _orderValidators, address[] memory _blockValidators) internal returns (address[] memory intersection) {
    //     for (uint32 i = 0; i < _orderValidators.length; i++) {
    //         for (uint32 j = 0; j < _blockValidators.length; j++) {
    //             if (_orderValidators[i] == _blockValidators[j]) {
    //                 intersection.push(_orderValidators[i]);
    //                 break;
    //             }
    //         }
    //     }
    // }

    /// @notice Check if the sender is rollup contract
    function requireRollup() internal view {
        require(
            msg.sender == rollupAddress,
            "ltrn11"
        ); // ltrn11 - only by rollup
    }

    /// @notice Check if the sender is owner contract
    function requireOwner() internal view {
        require(
            msg.sender == owner,
            "ltrr11"
        ); // ltrr11 - only by owner
    }
}