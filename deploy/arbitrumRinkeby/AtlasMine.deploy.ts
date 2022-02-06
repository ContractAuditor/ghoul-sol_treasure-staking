import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
    const { deployments, getNamedAccounts } = hre;
    const { deploy, execute, read } = deployments;
    const { deployer } = await getNamedAccounts();

    const magicArbitrum = "0x7693604341fDC5B73c920b8825518Ec9b6bBbb8b";
    const newOwner = "0x032F84aEfF59ddEBC55797F321624826d873bF65";

    const treasure = "0x6333F38F98f5c46dA6F873aCbF25DCf8748DDc2c";
    const legion = "0x96F791C0C11bAeE97526D5a9674494805aFBEc1c";
    const legionMetadataStore = "0x253dC801B38C79CcBFcECFDB2f5Bb5277c227537";

    await deploy('AtlasMine', {
      from: deployer,
      log: true,
      proxy: {
        execute: {
          init: {
            methodName: "init",
            args: [magicArbitrum, (await deployments.get("MasterOfCoin")).address]
          }
        }
      }
    })

    if(await read('AtlasMine', 'treasure') != treasure) {
      await execute(
        'AtlasMine',
        { from: deployer, log: true },
        'setTreasure',
        treasure
      );
    }

    if(await read('AtlasMine', 'legion') != legion) {
      await execute(
        'AtlasMine',
        { from: deployer, log: true },
        'setLegion',
        legion
      );
    }

    if(await read('AtlasMine', 'legionMetadataStore') != legionMetadataStore) {
      await execute(
        'AtlasMine',
        { from: deployer, log: true },
        'setLegionMetadataStore',
        legionMetadataStore
      );
    }

    const ATLAS_MINE_ADMIN_ROLE = await read('AtlasMine', 'ATLAS_MINE_ADMIN_ROLE');

    if(!(await read('AtlasMine', 'hasRole', ATLAS_MINE_ADMIN_ROLE, newOwner))) {
      await execute(
        'AtlasMine',
        { from: deployer, log: true },
        'grantRole',
        ATLAS_MINE_ADMIN_ROLE,
        newOwner
      );
    }
};
export default func;
func.tags = ['AtlasMine'];
func.dependencies = ['MasterOfCoin']
