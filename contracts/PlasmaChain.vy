struct deposit:
    untypedStart: uint256
    depositer: address
    precedingPlasmaBlockNumber: uint256

struct exitableRange:
    untypedStart: uint256
    isSet: bool

struct Exit:
    exiter: address
    plasmaBlockNumber: uint256
    ethBlockNumber: uint256
    tokenType: uint256
    untypedStart: uint256
    untypedEnd: uint256
    challengeCount: uint256

struct inclusionChallenge:
    exitID: uint256
    ongoing: bool

struct invalidHistoryChallenge:
    exitID: uint256
    coinID: uint256
    blockNumber: uint256
    recipient: address
    ongoing: bool

struct tokenListing:
    # formula: ERC20 amount = (plasma coin amount * 10^decimalOffset)
    decimalOffset:  uint256 # the denomination offset between the plasma-wrapped coins and the ERC20's decimals.
    # address of the ERC20
    contractAddress: address

contract ERC20:
    def transferFrom(_from: address, _to: address, _value: uint256) -> bool: modifying
    def transfer(_to: address, _value: uint256) -> bool: modifying


# Events to log in web3
ListingEvent: event({tokenType: uint256, tokenAddress: address})
DepositEvent: event({depositer: indexed(address), tokenType: uint256, untypedStart: uint256, untypedEnd: uint256})
SubmitBlockEvent: event({blockNumber: indexed(uint256), submittedHash: indexed(bytes32)})
BeginExitEvent: event({tokenType: indexed(uint256), untypedStart: indexed(uint256), untypedEnd: indexed(uint256), exiter: address, exitID: uint256})
FinalizeExitEvent: event({tokenType: indexed(uint256), untypedStart: indexed(uint256), untypedEnd: indexed(uint256), exitID: uint256})
ChallengeEvent: event({exitID: uint256, challengeID: indexed(uint256)})

# operator related publics
operator: public(address)
nextPlasmaBlockNumber: public(uint256)
lastPublish: public(uint256) # ethereum block number of most recent plasma block
blockHashes: public(map(uint256, bytes32))

# token related publics
listings: public(map(uint256, tokenListing))
listingNonce: public(uint256)
listed: public(map(address, uint256)) #which address is what token type

weiDecimalOffset: public(uint256)

# deposit and exit related publics
exits: public(map(uint256, Exit))
exitNonce: public(uint256)
exitable: public(map(uint256, map(uint256, exitableRange))) # tokentype -> ( end -> start because it makes for cleaner code
deposits: public(map(uint256, map(uint256, deposit))) # first val is tokentype. also has end -> start for consistency
totalDeposited: public(uint256)

# challenge-related publics
inclusionChallenges: public(map(uint256, inclusionChallenge))
invalidHistoryChallenges: public(map(uint256, invalidHistoryChallenge))
challengeNonce: public(uint256)

isSetup: public(bool)

# period (of ethereum blocks) during which an exit can be challenged
CHALLENGE_PERIOD: constant(uint256) = 20
# period (of ethereum blocks) during which an invalid history history challenge can be responded
SPENTCOIN_CHALLENGE_PERIOD: constant(uint256) = CHALLENGE_PERIOD / 2
# minimum number of ethereum blocks between new plasma blocks
PLASMA_BLOCK_INTERVAL: constant(uint256) = 0

MAX_COINS_PER_TOKEN: public(uint256)

MAX_TREE_DEPTH: constant(int128) = 8
MAX_TRANSFERS: constant(uint256) = 4

# @public
# def ecrecover_util(message_hash: bytes32, signature: bytes[65]) -> address:
#     v: uint256 = extract32(slice(signature, start=0, len=32), 0, type=uint256)
#     r: uint256 = extract32(slice(signature, start=32, len=64), 0, type=uint256)
#     s: bytes[1] = slice(signature, start=64, len=1)
#     s_pad: uint256 = extract32(s, 0, type=uint256)
#
#     addr: address = ecrecover(message_hash, v, r, s_pad)
#     return addr

### BEGIN TRANSACTION DECODING SECION ###

# Note: TX Encoding Lengths
#
# The MAX_TRANSFERS should be a tunable constant, but vyper doesn't 
# support 'bytes[constant var]' so it has to be hardcoded.  The formula
# for calculating the encoding size is:
#     TX_BLOCK_DECODE_LEN + 
#     TX_NUM_TRANSFERS_LEN +
#     MAX_TRANSFERS * TRANSFER_LEN 
# Currently we take MAX_TRANSFERS = 4, so the max TX encoding bytes is:
# 4 + 1 + 4 * 68 = 277

@public
def getLeafHash(transactionEncoding: bytes[277]) -> bytes32:
    return sha3(transactionEncoding)

TX_BLOCKNUM_START: constant(int128) = 0
TX_BLOCKNUM_LEN: constant(int128) = 4
@public
def decodeBlockNumber(transactionEncoding: bytes[277]) -> uint256:
    bn: bytes[32] = slice(transactionEncoding,
            start = TX_BLOCKNUM_START,
            len = TX_BLOCKNUM_LEN)
    return convert(bn, uint256)

TX_NUM_TRANSFERS_START: constant(int128) = 4
TX_NUM_TRANSFERS_LEN: constant(int128) = 1
@public
def decodeNumTransfers(transactionEncoding: bytes[277]) -> uint256:
    num: bytes[2] = slice(transactionEncoding,
            start = TX_NUM_TRANSFERS_START,
            len = TX_NUM_TRANSFERS_LEN)
    return convert(num, uint256)

FIRST_TR_START: constant(int128) = 5
TR_LEN: constant(int128) = 68
@public
def decodeIthTransfer(
    index: int128,
    transactionEncoding: bytes[277]
) -> bytes[68]:
    transfer: bytes[68] = slice(transactionEncoding,
        start = TR_LEN * index + FIRST_TR_START,
        len = TR_LEN
    )
    return transfer

### BEGIN TRANSFER DECODING SECTION ###

@private
def bytes20ToAddress(addr: bytes[20]) -> address:
    padded: bytes[52] = concat(EMPTY_BYTES32, addr)
    return convert(convert(slice(padded, start=20, len=32), bytes32), address)

SENDER_START: constant(int128) = 0
SENDER_LEN: constant(int128) = 20
@public
def decodeSender(
    transferEncoding: bytes[68]
) -> address:
    addr: bytes[20] = slice(transferEncoding,
        start = SENDER_START,
        len = SENDER_LEN)
    return self.bytes20ToAddress(addr)

RECIPIENT_START: constant(int128) = 20
RECIPIENT_LEN: constant(int128) = 20
@public
def decodeRecipient(
    transferEncoding: bytes[68]
) -> address:
    addr: bytes[20] = slice(transferEncoding,
        start = RECIPIENT_START,
        len = RECIPIENT_LEN)
    return self.bytes20ToAddress(addr)

TR_TOKEN_START: constant(int128) = 40
TR_TOKEN_LEN: constant(int128) = 4
@public
def decodeTokenTypeBytes(
    transferEncoding: bytes[68]
) -> bytes[4]:
    tokenType: bytes[4] = slice(transferEncoding, 
        start = TR_TOKEN_START,
        len = TR_TOKEN_LEN)
    return tokenType

@public
def decodeTokenType(
    transferEncoding: bytes[68]
) -> uint256:
    return convert(
        self.decodeTokenTypeBytes(transferEncoding), 
        uint256
    )

@public
def getTypedFromTokenAndUntyped(tokenType: uint256, coinID: uint256) -> uint256:
    return coinID + tokenType * (256**12)

TR_UNTYPEDSTART_START: constant(int128) = 44
TR_UNTYPEDSTART_LEN: constant(int128) = 12
TR_UNTYPEDEND_START: constant(int128) = 56
TR_UNTYPEDEND_LEN: constant(int128) = 12
@public
def decodeTypedTransferRange(
    transferEncoding: bytes[68]
) -> (uint256, uint256): # start, end
    tokenType: bytes[4] = self.decodeTokenTypeBytes(transferEncoding)
    untypedStart: bytes[12] = slice(transferEncoding,
        start = TR_UNTYPEDSTART_START,
        len = TR_UNTYPEDSTART_LEN)
    untypedEnd: bytes[12] = slice(transferEncoding,
        start = TR_UNTYPEDEND_START,
        len = TR_UNTYPEDEND_LEN)
    return (
        convert(concat(tokenType, untypedStart), uint256),
        convert(concat(tokenType, untypedEnd), uint256)
    )

### BEGIN TRANSFERPROOF DECODING SECTION ###

# Note on TransferProofEncoding size:
# It will always really be at most 
# PARSED_SUM_LEN + LEAF_INDEX_LEN + ADDRESS_LEN + PROOF_COUNT_LEN + MAX_TREE_DEPTH * TREENODE_LEN
# = 16 + 16 + 20 + 1 + 8 * 48 = 437
# but because of dumb type casting in vyper, it thinks it *might* 
# be larger because we slice the TX encoding to get it.  So it has to be
# TRANSFERPROOF_COUNT_LEN + 437 * MAX_TRANSFERS = 1 + 1744 * 4 = 1749

TREENODE_LEN: constant(int128) = 48

PARSEDSUM_START: constant(int128) = 0
PARSEDSUM_LEN: constant(int128) = 16
@public
def decodeParsedSumBytes(
    transferProofEncoding: bytes[1749] 
) -> bytes[16]:
    parsedSum: bytes[16] = slice(transferProofEncoding,
        start = PARSEDSUM_START,
        len = PARSEDSUM_LEN)
    return parsedSum

LEAFINDEX_START: constant(int128) = 16
LEAFINDEX_LEN: constant(int128) = 16
@public
def decodeLeafIndex(
    transferProofEncoding: bytes[1749]
) -> int128:
    leafIndex: bytes[16] = slice(transferProofEncoding,
        start = LEAFINDEX_START,
        len = PARSEDSUM_LEN)
    return convert(leafIndex, int128)

SIG_START:constant(int128) = 32
SIGV_OFFSET: constant(int128) = 0
SIGV_LEN: constant(int128) = 1
SIGR_OFFSET: constant(int128) = 1
SIGR_LEN: constant(int128) = 32
SIGS_OFFSET: constant(int128) = 33
SIGS_LEN: constant(int128) = 32
@public
def decodeSignature(
    transferProofEncoding: bytes[1749]
) -> (
    bytes[1], # v
    bytes32, # r
    bytes32 # s
):
    sig: bytes[65] = slice(transferProofEncoding,
        start = SIG_START,
        len = SIGV_LEN + SIGR_LEN + SIGS_LEN
    )
    sigV: bytes[1] = slice(sig,
        start = SIGV_OFFSET,
        len = SIGV_LEN)
    sigR: bytes[32] = slice(sig,
        start = SIGR_OFFSET,
        len = SIGR_LEN)
    sigS: bytes[32] = slice(sig,
        start = SIGS_OFFSET,
        len = SIGS_LEN)
    return (
        sigV,
        convert(sigR, bytes32),
        convert(sigS, bytes32)
    )

NUMPROOFNODES_START: constant(int128) = 97
NUMPROOFNODES_LEN: constant(int128) = 1
@public
def decodeNumInclusionProofNodesFromTRProof(transferProof: bytes[1749]) -> int128:
    numNodes: bytes[1] = slice(
        transferProof,
        start = NUMPROOFNODES_START,
        len = NUMPROOFNODES_LEN
    )
    return convert(numNodes, int128)

INCLUSIONPROOF_START: constant(int128) = 98
@public
def decodeIthInclusionProofNode(
    index: int128,
    transferProofEncoding: bytes[1749]
) -> bytes[48]: # = MAX_TREE_DEPTH * TREENODE_LEN = 384 is what it should be but because of variable in slice vyper won't let us say that :(
    proofNode: bytes[48] = slice(transferProofEncoding, 
        start = index * TREENODE_LEN + INCLUSIONPROOF_START,
        len =  TREENODE_LEN)
    return proofNode

### BEGIN TRANSACTION PROOF DECODING SECTION ###

# The smart contract assumes the number of nodes in every TRProof are equal.
FIRST_TRANSFERPROOF_START: constant(int128) = 1
@public
def decodeNumInclusionProofNodesFromTXProof(transactionProof: bytes[1749]) -> int128:
    firstTransferProof: bytes[1749] = slice(
        transactionProof,
        start = FIRST_TRANSFERPROOF_START,
        len = NUMPROOFNODES_START + 1 # + 1 so we include the numNodes
    )
    return self.decodeNumInclusionProofNodesFromTRProof(firstTransferProof)


NUMTRPROOFS_START: constant(int128) = 0
NUMTRPROOFS_LEN: constant(int128) = 1
@public
def decodeNumTransactionProofs(
    transactionProofEncoding: bytes[1749]
) -> int128:
    numInclusionProofs: bytes[1] = slice(
        transactionProofEncoding,
        start = NUMTRPROOFS_START,
        len = NUMTRPROOFS_LEN
    )
    return convert(numInclusionProofs, int128)

@public
def decodeIthTransferProofWithNumNodes(
    index: int128,
    numInclusionProofNodes: int128,
    transactionProofEncoding: bytes[1749]
) -> bytes[1749]:
    transactionProofLen: int128 = (
        PARSEDSUM_LEN +
        LEAFINDEX_LEN +
        SIGS_LEN + SIGV_LEN + SIGR_LEN +
        NUMPROOFNODES_LEN + 
        TREENODE_LEN * numInclusionProofNodes
    )
    transferProof: bytes[1749] = slice(
        transactionProofEncoding,
        start = index * transactionProofLen + FIRST_TRANSFERPROOF_START,
        len = transactionProofLen
    )
    return transferProof

@public
def checkTransferProofAndGetTypedBounds(
    leafHash: bytes32,
    blockNum: uint256,
    transferProof: bytes[1749]
) -> (uint256, uint256): # typedimplicitstart, typedimplicitEnd
    parsedSum: bytes[16] = self.decodeParsedSumBytes(transferProof)
    numProofNodes: int128 = self.decodeNumInclusionProofNodesFromTRProof(transferProof)
    leafIndex: int128 = self.decodeLeafIndex(transferProof)

    computedNode: bytes[48] = concat(leafHash, parsedSum)
    totalSum: uint256 = convert(parsedSum, uint256)
    leftSum: uint256 = 0
    rightSum: uint256 = 0
    pathIndex: int128 = leafIndex
    
    for nodeIndex in range(MAX_TREE_DEPTH):
        if nodeIndex == numProofNodes:
            break
        proofNode: bytes[48] = self.decodeIthInclusionProofNode(nodeIndex, transferProof)
        siblingSum: uint256 = convert(slice(proofNode, start=32, len=16), uint256)
        totalSum += siblingSum
        hashed: bytes32
        if pathIndex % 2 == 0:
            hashed = sha3(concat(computedNode, proofNode))
            rightSum += siblingSum
        else:
            hashed = sha3(concat(proofNode, computedNode))
            leftSum += siblingSum
        totalSumAsBytes: bytes[16] = slice( #This is all a silly trick since vyper won't directly convert numbers to bytes[]...classic :P
            concat(EMPTY_BYTES32, convert(totalSum, bytes32)),
            start=48,
            len=16
        )
        computedNode = concat(hashed, totalSumAsBytes)
        pathIndex /= 2
    rootHash: bytes[32] = slice(computedNode, start=0, len=32)
    rootSum: uint256 = convert(slice(computedNode, start=32, len=16), uint256)
    assert convert(rootHash, bytes32) == self.blockHashes[blockNum]
    return (leftSum, rootSum - rightSum)

COINID_BYTES: constant(int128) = 16
PROOF_MAX_LENGTH: constant(uint256) = 384 # 384 = TREENODE_LEN (48) * MAX_TREE_DEPTH (8) 
ENCODING_LENGTH_PER_TRANSFER: constant(int128) = 165

@public
def checkTransactionProofAndGetTypedTransfer(
        transactionEncoding: bytes[277],
        transactionProofEncoding: bytes[1749],
        transferIndex: int128
    ) -> (
        address, # transfer.to
        address, # transfer.from
        uint256, # transfer.start (typed)
        uint256, # transfer.end (typed)
        uint256 # transaction plasmaBlockNumber
    ):
    leafHash: bytes32 = self.getLeafHash(transactionEncoding)
    plasmaBlockNumber: uint256 = self.decodeBlockNumber(transactionEncoding)


    numTransfers: int128 = convert(self.decodeNumTransfers(transactionEncoding), int128)
    numInclusionProofNodes: int128 = self.decodeNumInclusionProofNodesFromTXProof(transactionProofEncoding)

    requestedTypedTransferStart: uint256 # these will be the ones at the trIndex we are being asked about by the exit game
    requestedTypedTransferEnd: uint256
    requestedTransferTo: address
    requestedTransferFrom: address
    for i in range(MAX_TRANSFERS):
        if i == numTransfers: #loop for max possible transfers, but break so we don't go past
            break
        transferEncoding: bytes[68] = self.decodeIthTransfer(i, transactionEncoding)
        
        transferProof: bytes[1749] = self.decodeIthTransferProofWithNumNodes(
            i,
            numInclusionProofNodes,
            transactionProofEncoding
        )

        implicitTypedStart: uint256
        implicitTypedEnd: uint256

        (implicitTypedStart, implicitTypedEnd) = self.checkTransferProofAndGetTypedBounds(
            leafHash,
            plasmaBlockNumber,
            transferProof
        )

        transferTypedStart: uint256
        transferTypedEnd: uint256

        (transferTypedStart, transferTypedEnd) = self.decodeTypedTransferRange(transferEncoding)

        assert implicitTypedStart <= transferTypedStart
        assert transferTypedStart < transferTypedEnd
        assert transferTypedEnd <= implicitTypedEnd

        v: bytes[1] # v
        r: bytes32 # r
        s: bytes32 # s
        (v, r, s) = self.decodeSignature(transferProof)
        sender: address = self.decodeSender(transferEncoding)
        # TODO: add signature check here!

        if i == transferIndex:
            requestedTransferTo = self.decodeRecipient(transferEncoding)
            requestedTransferFrom = sender
            requestedTypedTransferStart = transferTypedStart
            requestedTypedTransferEnd = transferTypedEnd


    return (
        requestedTransferTo,
        requestedTransferFrom,
        requestedTypedTransferStart,
        requestedTypedTransferEnd,
        plasmaBlockNumber
    )

### BEGIN CONTRACT LOGIC ###

@public
def setup(_operator: address, ethDecimalOffset: uint256): # last val should be properly hardcoded as a constant eventually
    assert self.isSetup == False
    self.operator = _operator
    self.nextPlasmaBlockNumber = 1 # starts at 1 so deposits before the first block have a precedingPlasmaBlock of 0 since it can't be negative (it's a uint)
    self.exitNonce = 0
    self.lastPublish = 0
    self.challengeNonce = 0
    self.totalDeposited = 0
    self.exitable[0][0].isSet = True
    self.listingNonce = 1 # first list is ETH baby!!!

    self.MAX_COINS_PER_TOKEN = 256**12
    self.weiDecimalOffset = ethDecimalOffset

    self.isSetup = True
    
@public
def submitBlock(newBlockHash: bytes32):
    assert msg.sender == self.operator
    assert block.number >= self.lastPublish + PLASMA_BLOCK_INTERVAL

    #log the event for clients to check for
    log.SubmitBlockEvent(self.nextPlasmaBlockNumber, newBlockHash)

    # add the block to the contract
    self.blockHashes[self.nextPlasmaBlockNumber] = newBlockHash
    self.nextPlasmaBlockNumber += 1
    self.lastPublish = block.number

@public
def listToken(tokenAddress: address, denomination: uint256):
    assert msg.sender == self.operator
    
    tokenType: uint256 = self.listingNonce
    self.listingNonce += 1

    self.listed[tokenAddress] = tokenType

    self.listings[tokenType].decimalOffset = denomination
    self.listings[tokenType].contractAddress = tokenAddress

    self.exitable[tokenType][0].isSet = True # init the new token exitable ranges
    log.ListingEvent(tokenType, tokenAddress)

### BEGIN DEPOSITS AND EXITS SECTION ###

@private
def processDeposit(depositer: address, depositAmount: uint256, tokenType: uint256):
    assert depositAmount > 0

    oldUntypedEnd: uint256 = self.totalDeposited
    oldRange: exitableRange = self.exitable[tokenType][oldUntypedEnd] # remember, map is end -> start!

    self.totalDeposited += depositAmount # add deposit
    newUntypedEnd: uint256 = self.totalDeposited # this is how much there is now, so the end of this deposit.
    # removed, replace with per ERC -->    assert self.totalDeposited < MAX_END # make sure we're not at capacity
    clear(self.exitable[tokenType][oldUntypedEnd]) # delete old exitable range
    self.exitable[tokenType][newUntypedEnd] = oldRange #make exitable

    self.deposits[tokenType][newUntypedEnd].untypedStart = oldUntypedEnd # the range (oldUntypedEnd, newTotalDeposited) was deposited by the depositer
    self.deposits[tokenType][newUntypedEnd].depositer = depositer
    self.deposits[tokenType][newUntypedEnd].precedingPlasmaBlockNumber = self.nextPlasmaBlockNumber - 1

    # log the deposit so participants can take note
    log.DepositEvent(depositer, tokenType, oldUntypedEnd, newUntypedEnd)


@public
@payable
def depositETH():
    weiMuiltiplier: uint256 = 10**self.weiDecimalOffset
    depositAmount: uint256 = as_unitless_number(msg.value) * weiMuiltiplier
    self.processDeposit(msg.sender, depositAmount, 0)

@public
def depositERC20(tokenAddress: address, depositSize: uint256):
    depositer: address = msg.sender

    tokenType: uint256 = self.listed[tokenAddress]
    assert tokenType > 0 # make sure it's been listed

    passed: bool = ERC20(tokenAddress).transferFrom(depositer, self, depositSize)
    assert passed

    tokenMultiplier: uint256 = 10**self.listings[tokenType].decimalOffset
    depositInPlasmaCoins: uint256 = depositSize * tokenMultiplier
    self.processDeposit(depositer, depositInPlasmaCoins, tokenType)

#add process above

@public
def beginExit(tokenType: uint256, blockNumber: uint256, untypedStart: uint256, untypedEnd: uint256) -> uint256:
    assert blockNumber < self.nextPlasmaBlockNumber

    exiter: address = msg.sender

    exitID: uint256 = self.exitNonce
    self.exits[exitID].exiter = exiter
    self.exits[exitID].plasmaBlockNumber = blockNumber
    self.exits[exitID].ethBlockNumber = block.number
    self.exits[exitID].tokenType = tokenType
    self.exits[exitID].untypedStart = untypedStart
    self.exits[exitID].untypedEnd = untypedEnd
    self.exits[exitID].challengeCount = 0

    self.exitNonce += 1
    return exitID

    #log the event
    log.BeginExitEvent(tokenType, untypedStart, untypedEnd, exiter, exitID)


@public
def checkRangeExitable(tokenType: uint256, untypedStart: uint256, untypedEnd: uint256, claimedExitableEnd: uint256):
    assert untypedEnd <= self.MAX_COINS_PER_TOKEN
    assert untypedEnd <= claimedExitableEnd
    assert untypedStart >= self.exitable[tokenType][claimedExitableEnd].untypedStart
    assert self.exitable[tokenType][claimedExitableEnd].isSet

# this function updates the exitable ranges to reflect a newly finalized exit.
@private
def removeFromExitable(tokenType: uint256, untypedStart: uint256, untypedEnd: uint256, exitableEnd: uint256):
    oldUntypedStart: uint256 = self.exitable[tokenType][exitableEnd].untypedStart
    #todo fix/check  the case with totally filled exit finalization
    if untypedStart != oldUntypedStart: # then we have a new exitable region to the left
        self.exitable[tokenType][untypedStart].untypedStart = oldUntypedStart # new exitable range from oldstart to the start of the exit (which has just become the end of the new exitable range)
        self.exitable[tokenType][untypedStart].isSet = True
    if untypedEnd != exitableEnd: # then we have leftovers to the right which are exitable
        self.exitable[tokenType][exitableEnd].untypedStart = untypedEnd # and it starts at the end of the finalized exit!
        self.exitable[tokenType][exitableEnd].isSet = True
    else: # otherwise, no leftovers on the right, so we can delete the map entry...
        if untypedEnd != self.totalDeposited: # ...UNLESS it's the rightmost deposited value, which we need to keep (even though it will be "empty", i.e. have start == end,because submitDeposit() uses it to make the new deposit exitable)
            clear(self.exitable[tokenType][untypedEnd])
        else: # and if it is the rightmost, 
            self.exitable[tokenType][untypedEnd].untypedStart = untypedEnd # start = end so won't ever be exitable, but allows for new deposit logic to work


@public
def finalizeExit(exitID: uint256, exitableEnd: uint256):
    exiter: address = self.exits[exitID].exiter
    exitETHBlockNumber: uint256 = self.exits[exitID].ethBlockNumber
    exitToken: uint256 = 0
    exitUntypedStart: uint256  = self.exits[exitID].untypedStart
    exitUntypedEnd: uint256 = self.exits[exitID].untypedEnd
    challengeCount: uint256 = self.exits[exitID].challengeCount
    tokenType: uint256 = self.exits[exitID].tokenType

    assert challengeCount == 0
    assert block.number > exitETHBlockNumber + CHALLENGE_PERIOD

    self.checkRangeExitable(tokenType, exitUntypedStart, exitUntypedEnd, exitableEnd)
    self.removeFromExitable(tokenType, exitUntypedStart, exitUntypedEnd, exitableEnd)

    if tokenType == 0: # then we're exiting ETH
        weiMiltiplier: uint256 = 10**self.weiDecimalOffset
        exitValue: uint256 = (exitUntypedEnd - exitUntypedStart) / weiMiltiplier
        send(exiter, as_wei_value(exitValue, "wei"))
    else: #then we're exiting ERC
        tokenMultiplier: uint256 = 10**self.listings[tokenType].decimalOffset
        exitValue: uint256 = (exitUntypedEnd - exitUntypedStart) / tokenMultiplier
        
        passed: bool = ERC20(self.listings[tokenType].contractAddress).transfer(exiter, exitValue)
        assert passed

    # log the event    
    log.FinalizeExitEvent(tokenType, exitUntypedStart, exitUntypedEnd, exitID)

@public
def challengeBeforeDeposit(
    exitID: uint256,
    coinID: uint256,
    depositUntypedEnd: uint256
):
    exitTokenType: uint256 = self.exits[exitID].tokenType

    # note: this can always be challenged because no response and all info on-chain, no invalidity period needed
    depositPrecedingPlasmaBlock: uint256 = self.deposits[exitTokenType][depositUntypedEnd].precedingPlasmaBlockNumber
    assert self.deposits[exitTokenType][depositUntypedEnd].depositer != ZERO_ADDRESS # requires the deposit to be a valid deposit and not something unset
    
    depositUntypedStart: uint256 = self.deposits[exitTokenType][depositUntypedEnd].untypedStart

    tokenType: uint256 = self.exits[exitID].tokenType
    depositTypedStart: uint256 = self.getTypedFromTokenAndUntyped(tokenType, depositUntypedStart)
    depositTypedEnd: uint256 = self.getTypedFromTokenAndUntyped(tokenType, depositUntypedEnd)

    assert coinID >= depositTypedStart
    assert coinID < depositTypedEnd

    assert depositPrecedingPlasmaBlock > self.exits[exitID].plasmaBlockNumber

    clear(self.exits[exitID])

@public
def challengeInclusion(exitID: uint256):
    # check the exit being challenged exists
    assert exitID < self.exitNonce

    # check we can still challenge
    exitethBlockNumber: uint256 = self.exits[exitID].ethBlockNumber
    assert block.number < exitethBlockNumber + CHALLENGE_PERIOD

    # store challenge
    challengeID: uint256 = self.challengeNonce
    self.inclusionChallenges[challengeID].exitID = exitID

    self.inclusionChallenges[challengeID].ongoing = True
    self.exits[exitID].challengeCount += 1

    self.challengeNonce += 1

    # log the event so clients can respond
    log.ChallengeEvent(exitID, challengeID)

@public
def respondTransactionInclusion(
        challengeID: uint256,
        transferIndex: int128,
        transactionEncoding: bytes[277],
        transactionProofEncoding: bytes[1749],
):
    assert self.inclusionChallenges[challengeID].ongoing

    transferTypedStart: uint256 # these will be the ones at the trIndex we are being asked about by the exit game
    transferTypedEnd: uint256
    transferRecipient: address
    transferSender: address
    responseBlockNumber: uint256

    (
        transferRecipient,
        transferSender,
        transferTypedStart, 
        transferTypedEnd, 
        responseBlockNumber
    ) = self.checkTransactionProofAndGetTypedTransfer(
        transactionEncoding,
        transactionProofEncoding,
        transferIndex
    )

    exitID: uint256 = self.inclusionChallenges[challengeID].exitID
    exiter: address = self.exits[exitID].exiter
    exitPlasmaBlockNumber: uint256 = self.exits[exitID].plasmaBlockNumber

    # check exit exiter is indeed recipient
    assert transferRecipient == exiter

    #check the inclusion was indeed at this block
    assert exitPlasmaBlockNumber == responseBlockNumber

    # response was successful
    clear(self.inclusionChallenges[challengeID])
    self.exits[exitID].challengeCount -= 1

@public
def respondDepositInclusion(
    challengeID: uint256,
    depositEnd: uint256
):
    assert self.inclusionChallenges[challengeID].ongoing
    
    exitID: uint256 = self.inclusionChallenges[challengeID].exitID
    exiter: address = self.exits[exitID].exiter
    exitPlasmaBlockNumber: uint256 = self.exits[exitID].plasmaBlockNumber
    exitTokenType: uint256 = self.exits[exitID].tokenType

    # check exit exiter is indeed recipient
    depositer: address = self.deposits[exitTokenType][depositEnd].depositer
    assert depositer == exiter

    #check the inclusion was indeed at this block
    depositBlockNumber: uint256 = self.deposits[exitTokenType][depositEnd].precedingPlasmaBlockNumber
    assert exitPlasmaBlockNumber == depositBlockNumber

    # response was successful
    clear(self.inclusionChallenges[challengeID])
    self.exits[exitID].challengeCount -= 1

@public
def challengeSpentCoin(
    exitID: uint256,
    coinID: uint256,
    transferIndex: int128,
    transactionEncoding: bytes[277],
    transactionProofEncoding: bytes[1749],
):
    # check we can still challenge
    exitethBlockNumberNumber: uint256 = self.exits[exitID].ethBlockNumber
    # assert block.number < exitethBlockNumberNumber + SPENTCOIN_CHALLENGE_PERIOD

    transferTypedStart: uint256 # these will be the ones at the trIndex we are being asked about by the exit game
    transferTypedEnd: uint256
    transferRecipient: address
    transferSender: address
    bn: uint256

    (
        transferRecipient,
        transferSender,
        transferTypedStart, 
        transferTypedEnd, 
        bn
    ) = self.checkTransactionProofAndGetTypedTransfer(
        transactionEncoding,
        transactionProofEncoding,
        transferIndex
    )

    exiter: address = self.exits[exitID].exiter
    exitPlasmaBlockNumber: uint256 = self.exits[exitID].plasmaBlockNumber
    exitTokenType: uint256 = self.exits[exitID].tokenType
    exitTypedStart: uint256 = self.getTypedFromTokenAndUntyped(exitTokenType, self.exits[exitID].untypedStart)
    exitTypedEnd: uint256 = self.getTypedFromTokenAndUntyped(exitTokenType, self.exits[exitID].untypedEnd)

    # check the coinspend came after the exit block
    assert bn > exitPlasmaBlockNumber

    # check the coinspend intersects both the exit and proven transfer
    assert coinID >=  exitTypedStart
    assert coinID < exitTypedEnd
    assert coinID >= transferTypedStart
    assert coinID < transferTypedEnd

    # check the sender was the exiter
    assert transferSender == exiter

    # if all these passed, the coin was indeed spent.  CANCEL!
    clear(self.exits[exitID])

@private
def challengeInvalidHistory(
    exitID: uint256,
    coinID: uint256,
    claimant: address,
    typedStart: uint256,
    typedEnd: uint256,
    blockNumber: uint256
):
    # check we can still challenge
    exitethBlockNumberNumber: uint256 = self.exits[exitID].ethBlockNumber
    assert block.number < exitethBlockNumberNumber + CHALLENGE_PERIOD

    # check the coinspend came before the exit block
    assert blockNumber < self.exits[exitID].plasmaBlockNumber

    # check the coinspend intersects the exit
    tokenType: uint256 = self.exits[exitID].tokenType
    exitTypedStart: uint256 = self.getTypedFromTokenAndUntyped(tokenType, self.exits[exitID].untypedStart)
    exitTypedEnd: uint256 = self.getTypedFromTokenAndUntyped(tokenType, self.exits[exitID].untypedEnd)

    assert coinID >= exitTypedStart
    assert coinID < exitTypedEnd

    # check the coinspend intersects the proven transfer
    assert coinID >= typedStart
    assert coinID < typedEnd

    # check the exit being challenged exists
    assert exitID < self.exitNonce

    # get and increment challengeID
    challengeID: uint256 = self.challengeNonce
    self.exits[exitID].challengeCount += 1
    
    self.challengeNonce += 1

    # store challenge
    self.invalidHistoryChallenges[challengeID].ongoing = True
    self.invalidHistoryChallenges[challengeID].exitID = exitID
    self.invalidHistoryChallenges[challengeID].coinID = coinID
    self.invalidHistoryChallenges[challengeID].recipient = claimant
    self.invalidHistoryChallenges[challengeID].blockNumber = blockNumber

    # log the event so clients can respond
    log.ChallengeEvent(exitID, challengeID)

@public
def challengeInvalidHistoryWithTransaction(
    exitID: uint256,
    coinID: uint256,
    transferIndex: int128,
    transactionEncoding: bytes[277],
    transactionProofEncoding: bytes[1749]
):
    transferTypedStart: uint256 # these will be the ones at the trIndex we are being asked about by the exit game
    transferTypedEnd: uint256
    transferRecipient: address
    transferSender: address
    bn: uint256
    (
        transferRecipient,
        transferSender,
        transferTypedStart, 
        transferTypedEnd, 
        bn
    ) = self.checkTransactionProofAndGetTypedTransfer(
        transactionEncoding,
        transactionProofEncoding,
        transferIndex
    )

    self.challengeInvalidHistory(
        exitID,
        coinID,
        transferRecipient,
        transferTypedStart,
        transferTypedEnd,
        bn
    )

@public
def challengeInvalidHistoryWithDeposit(
    exitID: uint256,
    coinID: uint256,
    depositUntypedEnd: uint256
):
    tokenType: uint256 = self.exits[exitID].tokenType
    depositer: address = self.deposits[tokenType][depositUntypedEnd].depositer
    assert depositer != ZERO_ADDRESS # make sure the deposit was really set/valid

    # get typed deposit bounds
    depositBlockNumber: uint256 = self.deposits[tokenType][depositUntypedEnd].precedingPlasmaBlockNumber

   # check the coinspend intersects the exit
    depositTypedStart: uint256 = self.getTypedFromTokenAndUntyped(tokenType, self.deposits[tokenType][depositUntypedEnd].untypedStart)
    depositTypedEnd: uint256 = self.getTypedFromTokenAndUntyped(tokenType, depositUntypedEnd)

    self.challengeInvalidHistory(
        exitID,
        coinID,
        depositer,
        depositTypedStart,
        depositTypedEnd,
        depositBlockNumber
    )

@public
def respondInvalidHistoryTransaction(
        challengeID: uint256,
        transferIndex: int128,
        transactionEncoding: bytes[277],
        transactionProofEncoding: bytes[1749],
):

    assert self.invalidHistoryChallenges[challengeID].ongoing

    transferTypedStart: uint256 # these will be the ones at the trIndex we are being asked about by the exit game
    transferTypedEnd: uint256
    transferRecipient: address
    transferSender: address
    bn: uint256

    (
        transferRecipient,
        transferSender,
        transferTypedStart, 
        transferTypedEnd, 
        bn
    ) = self.checkTransactionProofAndGetTypedTransfer(
        transactionEncoding,
        transactionProofEncoding,
        transferIndex
    )

    # check the response transfer addresses the challenged coin
    chalCoinID: uint256 = self.invalidHistoryChallenges[challengeID].coinID
    assert chalCoinID >= transferTypedStart
    assert chalCoinID  < transferTypedEnd

    # check exit the response's sender is indeed the challenge's recipient
    chalRecipient: address = self.invalidHistoryChallenges[challengeID].recipient
    assert chalRecipient == transferSender

    # check the response was between exit and challenge
    exitID: uint256 = self.invalidHistoryChallenges[challengeID].exitID
    exitPlasmaBlockNumber: uint256 = self.exits[exitID].plasmaBlockNumber
    chalBlockNumber: uint256 = self.invalidHistoryChallenges[challengeID].blockNumber
    
    assert bn > chalBlockNumber
    assert bn <= exitPlasmaBlockNumber

    # response was successful
    clear(self.invalidHistoryChallenges[challengeID])
    self.exits[exitID].challengeCount -= 1

@public
def respondInvalidHistoryDeposit(
    challengeID: uint256,
    depositUntypedEnd: uint256
):
    assert self.invalidHistoryChallenges[challengeID].ongoing

    exitID: uint256 = self.invalidHistoryChallenges[challengeID].exitID
    exitTokenType: uint256 = self.exits[exitID].tokenType

    #check the deposit is real
    assert self.deposits[exitTokenType][depositUntypedEnd].depositer != ZERO_ADDRESS

    #check the response deposit addresses the right coinID
    chalCoinID: uint256 = self.invalidHistoryChallenges[challengeID].coinID
    depositUntypedStart: uint256 = self.deposits[exitTokenType][depositUntypedEnd].untypedStart

    depositTypedStart: uint256 = self.getTypedFromTokenAndUntyped(exitTokenType, depositUntypedStart)
    depositTypedEnd: uint256 = self.getTypedFromTokenAndUntyped(exitTokenType, depositUntypedEnd)
    
    assert chalCoinID >= depositTypedStart
    assert chalCoinID <= depositTypedEnd

    # check the response was between exit and challenge
    chalBlockNumber: uint256 = self.invalidHistoryChallenges[challengeID].blockNumber
    exitPlasmaBlockNumber: uint256 = self.exits[exitID].plasmaBlockNumber
    depositBlockNumber: uint256 = self.deposits[exitTokenType][depositUntypedEnd].precedingPlasmaBlockNumber
    
    assert depositBlockNumber > chalBlockNumber
    assert depositBlockNumber <= exitPlasmaBlockNumber

    # response was successful
    clear(self.invalidHistoryChallenges[challengeID])
    self.exits[exitID].challengeCount -= 1