import HSCryptoKit
import RealmSwift
import GRDB

class BlockSyncer {
    private let storage: IStorage

    private let listener: ISyncStateListener
    private let network: INetwork
    private let factory: IFactory
    private let transactionProcessor: ITransactionProcessor
    private let blockchain: IBlockchain
    private let addressManager: IAddressManager
    private let bloomFilterManager: IBloomFilterManager

    private let hashCheckpointThreshold: Int
    private var state: BlockSyncerState

    private let logger: Logger?

    init(storage: IStorage, network: INetwork, factory: IFactory, listener: ISyncStateListener, transactionProcessor: ITransactionProcessor,
         blockchain: IBlockchain, addressManager: IAddressManager, bloomFilterManager: IBloomFilterManager,
         hashCheckpointThreshold: Int = 100, logger: Logger? = nil, state: BlockSyncerState = BlockSyncerState()
    ) {
        self.storage = storage
        self.network = network
        self.factory = factory
        self.transactionProcessor = transactionProcessor
        self.blockchain = blockchain
        self.addressManager = addressManager
        self.bloomFilterManager = bloomFilterManager
        self.hashCheckpointThreshold = hashCheckpointThreshold
        self.listener = listener

        self.logger = logger
        self.state = state

        if storage.blocksCount == 0 {
            storage.save(block: network.checkpointBlock)
        }

        listener.initialBestBlockHeightUpdated(height: localDownloadedBestBlockHeight)
    }

    var localDownloadedBestBlockHeight: Int32 {
        let height = storage.lastBlock?.height
        return Int32(height ?? 0)
    }

    var localKnownBestBlockHeight: Int32 {
        let blockchainHashes = storage.blockchainBlockHashes
        let existingHashesCount = storage.blocksCount(reversedHeaderHashHexes: blockchainHashes.map { $0.reversedHeaderHashHex })
        return localDownloadedBestBlockHeight + Int32(blockchainHashes.count - existingHashesCount)
    }

    // We need to clear block hashes when sync peer is disconnected
    private func clearBlockHashes() {
        storage.deleteBlockchainBlockHashes()
    }

    private func clearPartialBlocks() throws {
        let blockReversedHashes = storage.blockHashHeaderHashHexes(except: network.checkpointBlock.reversedHeaderHashHex)

        try storage.inTransaction { realm in
            let blocksToDelete = storage.blocks(byHexes: blockReversedHashes, realm: realm)
            blockchain.deleteBlocks(blocks: blocksToDelete, realm: realm)
        }
    }

    private func handlePartialBlocks() throws {
        try addressManager.fillGap()
        bloomFilterManager.regenerateBloomFilter()
        state.iteration(hasPartialBlocks: false)
    }

}

extension BlockSyncer: IBlockSyncer {

    func prepareForDownload() {
        do {
            try handlePartialBlocks()
            try clearPartialBlocks()
            clearBlockHashes()

            blockchain.handleFork(realm: storage.realm)
        } catch {
            logger?.error(error)
        }
    }

    func downloadStarted() {
    }

    func downloadIterationCompleted() {
        if state.iterationHasPartialBlocks {
            try? handlePartialBlocks()
        }
    }

    func downloadCompleted() {
        blockchain.handleFork(realm: storage.realm)
    }

    func downloadFailed() {
        prepareForDownload()
    }

    func getBlockHashes() -> [BlockHash] {
        return storage.blockHashes(sortedBy: .order, secondSortedBy: .height, limit: 500)
    }

    func getBlockLocatorHashes(peerLastBlockHeight: Int32) -> [Data] {
        var blockLocatorHashes = [Data]()

        if let lastBlockHash = storage.lastBlockchainBlockHash {
            blockLocatorHashes.append(lastBlockHash.headerHash)
        }

        if blockLocatorHashes.isEmpty {
            for block in storage.blocks(heightGreaterThan: network.checkpointBlock.height, sortedBy: "height", limit: 10) {
                blockLocatorHashes.append(block.headerHash)
            }
        }

        if let peerLastBlock = storage.block(byHeight: peerLastBlockHeight) {
            if !blockLocatorHashes.contains(peerLastBlock.headerHash) {
                blockLocatorHashes.append(peerLastBlock.headerHash)
            }
        } else {
            blockLocatorHashes.append(network.checkpointBlock.headerHash)
        }

        return blockLocatorHashes
    }

    func add(blockHashes: [Data]) {
        var lastOrder = storage.lastBlockHash?.order ?? 0
        let existingHashes = storage.blockHashHeaderHashes

        let blockHashes: [BlockHash] = blockHashes
                .filter {
                    !existingHashes.contains($0)
                }.map {
                    lastOrder += 1
                    return factory.blockHash(withHeaderHash: $0, height: 0, order: lastOrder)
                }

        storage.add(blockHashes: blockHashes)
    }

    func handle(merkleBlock: MerkleBlock, maxBlockHeight: Int32) throws {
        var block: Block!

        try storage.inTransaction { realm in
            if let height = merkleBlock.height {
                block = blockchain.forceAdd(merkleBlock: merkleBlock, height: height, realm: realm)
            } else {
                block = try blockchain.connect(merkleBlock: merkleBlock, realm: realm)
            }

            do {
                try transactionProcessor.process(transactions: merkleBlock.transactions, inBlock: block, skipCheckBloomFilter: self.state.iterationHasPartialBlocks, realm: realm)
            } catch _ as BloomFilterManager.BloomFilterExpired {
                state.iteration(hasPartialBlocks: true)
            }

            if !state.iterationHasPartialBlocks {
                storage.deleteBlockHash(byHashHex: block.reversedHeaderHashHex)
            }
        }

        listener.currentBestBlockHeightUpdated(height: Int32(block.height), maxBlockHeight: maxBlockHeight)
    }

    func shouldRequestBlock(withHash hash: Data) -> Bool {
        return storage.block(byHeaderHash: hash) == nil
    }

}
