// import { HardhatRuntimeEnvironment } from "hardhat/types";
// import { DeployFunction } from "hardhat-deploy/types";

// const deploy: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
//   const { deployments, getNamedAccounts } = hre;
//   // eslint-disable-next-line @typescript-eslint/unbound-method
//   const { deploy } = deployments;
//   const namedAccounts = await getNamedAccounts();
//   const { deployer } = namedAccounts;

//   await deploy("BatchTransfer", {
//     from: deployer,
//     proxy: {
//       proxyContract: "OpenZeppelinTransparentProxy",
//       execute: {
//         init: {
//           methodName: "initialize",
//           args: [],
//         },
//       },
//     },
//     log: true,
//   });
// };
// deploy.tags = ["Setup"];

// export default deploy;
