import {HardhatRuntimeEnvironment} from 'hardhat/types';
import {DeployFunction} from 'hardhat-deploy/types';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  console.log(hre);
  const {deployments, getNamedAccounts} = hre;
  const {deploy} = deployments;

  const {deployer} = await getNamedAccounts();

  await deploy('UniswapV2Factory', {
    from: deployer,
    args: [deployer],
    log: true,
  });
};
export default func;
func.tags = ['UniswapV2Factory'];
