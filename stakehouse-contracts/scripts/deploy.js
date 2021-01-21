'use strict';

// Imports.
const hre = require('hardhat');
const ethers = hre.ethers;

// Configuration for this deployment.
const itemInitialSupplies = [ 0, 0, 0, 0, 0 ];
const itemMaximumSupplies = [ 100, 100, 100, 100, 100 ];
const itemPrices = [
	ethers.utils.parseEther('0.01'),
	ethers.utils.parseEther('0.01'),
	ethers.utils.parseEther('0.01'),
	ethers.utils.parseEther('0.01'),
	ethers.utils.parseEther('0.01')
];

// Log the gas cost of a transaction.
async function logTransactionGas (transaction) {
	let transactionReceipt = await transaction.wait();
	let transactionGasCost = transactionReceipt.cumulativeGasUsed;
	console.log(` -> Gas cost: ${transactionGasCost.toString()}`);
	return transactionGasCost;
}

// Deploy using an Ethers signer to a network.
async function main () {
	const signers = await ethers.getSigners();
	const addresses = await Promise.all(signers.map(async signer => signer.getAddress()));
	const deployer = { provider: signers[0].provider, signer: signers[0], address: addresses[0] };
	console.log(`Deploying contracts from: ${deployer.address}`);

	// Create a variable to track the total gas cost of deployment.
	let totalGasCost = ethers.utils.parseEther('0');

	// Retrieve contract artifacts and deploy them.
	const FarmTokenRecords = await ethers.getContractFactory('FarmTokenRecords');
	const FarmStakerRecords = await ethers.getContractFactory('FarmStakerRecords');
	const FarmShopRecords = await ethers.getContractFactory('FarmShopRecords');
	const FarmItemRecords = await ethers.getContractFactory('FarmItemRecords');
	const FeeOwner = await ethers.getContractFactory('FeeOwner');
	const ShopEtherMinter1155 = await ethers.getContractFactory('ShopEtherMinter1155');
	const Fee1155 = await ethers.getContractFactory('Fee1155');

	// Deploy a FeeOwner for the Stakehouse platform.
	let platformFeeOwner = await FeeOwner.connect(deployer.signer).deploy('2500', '10000');
	let platformFeeDeploy = await platformFeeOwner.deployed();
	console.log(`* Platform FeeOwner deployed to: ${platformFeeOwner.address}`);
	totalGasCost = totalGasCost.add(await logTransactionGas(platformFeeDeploy.deployTransaction));

	// Deploy the FarmRecords registry contracts.
	let farmTokenRecords = await FarmTokenRecords.connect(deployer.signer).deploy();
	let farmRecordsDeploy = await farmTokenRecords.deployed();
	console.log(`* FarmTokenRecords deployed to: ${farmTokenRecords.address}`);
	totalGasCost = totalGasCost.add(await logTransactionGas(farmRecordsDeploy.deployTransaction));
	let farmStakerRecords = await FarmStakerRecords.connect(deployer.signer).deploy();
	farmRecordsDeploy = await farmStakerRecords.deployed();
	console.log(`* FarmStakerRecords deployed to: ${farmStakerRecords.address}`);
	totalGasCost = totalGasCost.add(await logTransactionGas(farmRecordsDeploy.deployTransaction));
	let farmShopRecords = await FarmShopRecords.connect(deployer.signer).deploy(platformFeeOwner.address);
	farmRecordsDeploy = await farmShopRecords.deployed();
	console.log(`* FarmShopRecords deployed to: ${farmShopRecords.address}`);
	totalGasCost = totalGasCost.add(await logTransactionGas(farmRecordsDeploy.deployTransaction));
	let farmItemRecords = await FarmItemRecords.connect(deployer.signer).deploy();
	farmRecordsDeploy = await farmItemRecords.deployed();
	console.log(`* FarmItemRecords deployed to: ${farmItemRecords.address}`);
	totalGasCost = totalGasCost.add(await logTransactionGas(farmRecordsDeploy.deployTransaction));

	// Deploy a FeeOwner for the Stakehouse item royalties.
	let itemFeeOwner = await FeeOwner.connect(deployer.signer).deploy('10000', '20000');
	let itemFeeDeploy = await itemFeeOwner.deployed();
	console.log(`* Item FeeOwner deployed to: ${itemFeeOwner.address}`);
	totalGasCost = totalGasCost.add(await logTransactionGas(itemFeeDeploy.deployTransaction));

	// Deploy the item collection for the sale.
	let itemCollection = await Fee1155.connect(deployer.signer).deploy('', itemFeeOwner.address);
	let itemCollectionDeploy = await itemCollection.deployed();
	console.log(`* Item collection deployed to: ${itemCollection.address}`);
	totalGasCost = totalGasCost.add(await logTransactionGas(itemCollectionDeploy.deployTransaction));

	// Create the item groups.
	for (let i = 0; i < itemInitialSupplies.length; i++) {
		let itemInitialSupply = itemInitialSupplies[i];
		let itemMaximumSupply = itemMaximumSupplies[i];
		let itemIndexedInitialSupplies = [];
		let itemIndexedMaximumSupplies = [];
		let initialRecipients = [];
		for (let j = 0; j < itemMaximumSupply; j++) {
			itemIndexedInitialSupplies.push(itemInitialSupply);
			itemIndexedMaximumSupplies.push(itemMaximumSupply);
			initialRecipients.push(deployer.address);
		}
		let createTransaction = await itemCollection.connect(deployer.signer).create(itemIndexedInitialSupplies, itemIndexedMaximumSupplies, initialRecipients, []);
		console.log(` -> Creating item ${i} ...`);
		totalGasCost = totalGasCost.add(await logTransactionGas(createTransaction));
	}

	// Deploy the item shop.
	let shop = await ShopEtherMinter1155.connect(deployer.signer).deploy(itemCollection.address, platformFeeOwner.address);
	let shopDeploy = await shop.deployed();
	console.log(`* ShopEtherMinter1155 deployed to: ${shop.address}`);
	totalGasCost = totalGasCost.add(await logTransactionGas(shopDeploy.deployTransaction));

	// The deployer must approve the Shop to mint items on its behalf.
	let approveMinterTransaction = await itemCollection.connect(deployer.signer).approveMinter(shop.address, true);
	console.log(` -> Approving the Shop to mint items ...`);
	totalGasCost = totalGasCost.add(await logTransactionGas(approveMinterTransaction));

	// List the items in the shop.
	let listTransaction = await shop.connect(deployer.signer).listItems([ 0, 1, 2, 3, 4 ], itemPrices);
	console.log(` -> Listing items in the shop ...`);
	totalGasCost = totalGasCost.add(await logTransactionGas(listTransaction));

	// Output the final gas cost.
	console.log('');
	console.log(`=> Final gas cost of deployment: ${totalGasCost.toString()}`);

	// Benchmark a purchase operation.
	console.log('');
	let purchaseTransaction = await shop.connect(deployer.signer).purchaseItems([ 1 ], { value: ethers.utils.parseEther('0.01') });
	console.log(` -> Purchasing an item ...`);
	await logTransactionGas(purchaseTransaction);
}

// Execute the script and catch errors.
main()
	.then(() => process.exit(0))
	.catch(error => {
		console.error(error);
		process.exit(1);
	});
