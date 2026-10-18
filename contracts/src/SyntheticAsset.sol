// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/ISyntheticAsset.sol";

contract SyntheticAsset is ISyntheticAsset {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    bytes32 public override immutable currencyKey;

    address public issuer;
    uint256 public override totalSupply;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    modifier onlyIssuer() {
        require(msg.sender == issuer, "SYNTH: ONLY_ISSUER");
        _;
    }

    constructor(string memory _name, string memory _symbol, bytes32 _currencyKey, address _issuer) {
        name = _name;
        symbol = _symbol;
        currencyKey = _currencyKey;
        issuer = _issuer;
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        require(balanceOf[msg.sender] >= amount, "SYNTH: INSUFFICIENT_BALANCE");
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        emit Transfer(msg.sender, recipient, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = allowance[sender][msg.sender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "SYNTH: INSUFFICIENT_ALLOWANCE");
            allowance[sender][msg.sender] = currentAllowance - amount;
        }
        require(balanceOf[sender] >= amount, "SYNTH: INSUFFICIENT_BALANCE");
        balanceOf[sender] -= amount;
        balanceOf[recipient] += amount;
        emit Transfer(sender, recipient, amount);
        return true;
    }

    function mint(address account, uint256 amount) external override onlyIssuer {
        totalSupply += amount;
        balanceOf[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function burn(address account, uint256 amount) external override onlyIssuer {
        require(balanceOf[account] >= amount, "SYNTH: BURN_EXCEEDS_BALANCE");
        balanceOf[account] -= amount;
        totalSupply -= amount;
        emit Transfer(account, address(0), amount);
    }
}
