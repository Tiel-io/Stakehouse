// Configure environment variables.
require('dotenv').config();

// Include Babel so that we may use some newer JavaScript syntax.
require('@babel/register');

// Include Waffle with Ethers as our preferred engine for testing.
require('@nomiclabs/hardhat-waffle');

// Include the detailed gas usage reporter for tests.
require('hardhat-gas-reporter');

// Include the contract size output display.
require('hardhat-contract-sizer');

// Retrieve sensitive node and private key details from environment variables.
const INFURA_PROJECT_ID = process.env.INFURA_PROJECT_ID;
const KOVAN_PRIVATE_KEY = process.env.KOVAN_PRIVATE_KEY;

// Export a configuration for Hardhat to use when working with our contracts.
module.exports = {
	solidity: {
		version: '0.6.12',
		settings: {
			optimizer: {
				enabled: true
			}
		}
	},
	networks: {
		kovan: {
			url: `https://kovan.infura.io/v3/${INFURA_PROJECT_ID}`,
			accounts: [ `0x${KOVAN_PRIVATE_KEY}` ]
		}
	},
	mocha: {
		grep: '^(?!.*; using Ganache).*'
	}
};
