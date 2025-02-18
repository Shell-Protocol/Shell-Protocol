const { ethers } = require("hardhat");

const ABDK_ONE = ethers.BigNumber.from(2).pow(64);
const ONE = ethers.utils.parseEther('1')

const ms = [
    0.05521382224, 
    0.2607818221, 
    2.699536997, 
    11.06480908
].map((value) => ethers.BigNumber.from(BigInt(value * 1e18).toString()).mul(ABDK_ONE).div(ONE))

const _as = [
    -17.624579963309124, 
    0.8127636673531361, 
    0.9128540032864936, 
    0.8933760690685003, 
    0.0
].map((value) => ethers.BigNumber.from(BigInt(value * 1e18).toString()).mul(ABDK_ONE).div(ONE))

const bs = [
    0.0, 
    1.0179962138011822, 
    1.0440979539804842, 
    0.9915165499338794, 
    -8.89351909094997
].map((value) => ethers.BigNumber.from(BigInt(value * 1e18).toString()).mul(ABDK_ONE).div(ONE))

const ks = [
    1.0, 
    115.48076607752792, 
    433.8619656484687, 
    175.49816371383105, 
    2.017603375340969
].map((value) => ethers.BigNumber.from(BigInt(value * 1e18).toString()).mul(ABDK_ONE).div(ONE))

module.exports = { ms, _as, bs, ks }