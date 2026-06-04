import { EsploraBitcoinClient } from "@utxopia/sdk/btc-client";
import type { BitcoinDepositCandidate, BitcoinNetwork } from "@utxopia/sdk/btc-client";

export interface SuiBitcoinNodeConfig {
  network: BitcoinNetwork;
  esploraUrl?: string;
  minDepositConfirmations?: number;
}

export class SuiBitcoinNode {
  private readonly bitcoin: EsploraBitcoinClient;

  constructor(private readonly config: SuiBitcoinNodeConfig) {
    this.bitcoin = new EsploraBitcoinClient({
      network: config.network,
      baseUrl: config.esploraUrl,
    });
  }

  async getTipHeight(): Promise<number> {
    return this.bitcoin.getBlockHeight();
  }

  async findConfirmedDeposits(address: string): Promise<BitcoinDepositCandidate[]> {
    return this.bitcoin.findDepositCandidates(address, this.config.minDepositConfirmations ?? 1);
  }

  async broadcastRedemption(txHex: string): Promise<string> {
    return this.bitcoin.broadcastTx(txHex);
  }
}
