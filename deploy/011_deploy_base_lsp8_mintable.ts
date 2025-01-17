import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { ethers } from 'hardhat';

const deployBaseLSP8Mintable: DeployFunction = async ({
  deployments,
  getNamedAccounts,
}: HardhatRuntimeEnvironment) => {
  const { deploy } = deployments;
  const { owner } = await getNamedAccounts();

  await deploy('LSP8MintableInit', {
    from: owner,
    gasPrice: ethers.BigNumber.from(20_000_000_000), // in wei,
    log: true,
  });
};

export default deployBaseLSP8Mintable;
deployBaseLSP8Mintable.tags = ['LSP8MintableInit', 'base'];
