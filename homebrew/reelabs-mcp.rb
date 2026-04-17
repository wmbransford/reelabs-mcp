class ReelabsMcp < Formula
  desc "Native video editing MCP server for Claude"
  homepage "https://reelabs.ai"
  version "0.0.1"
  url "https://github.com/wmbransford/reelabs-mcp/releases/download/v#{version}/reelabs-mcp-#{version}-macos.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on :macos => :sequoia

  def install
    bin.install "ReelabsMCP" => "reelabs-mcp"
  end

  service do
    run opt_bin/"reelabs-mcp"
    keep_alive true
    log_path "/tmp/reelabs-mcp.stdout.log"
    error_log_path "/tmp/reelabs-mcp.stderr.log"
  end

  def caveats
    <<~EOS
      Start the MCP server as a background service:
        brew services start reelabs-mcp

      Connect this device to your ReeLabs account:
        reelabs-mcp sign-in

      The server listens on http://127.0.0.1:52849/mcp
    EOS
  end

  test do
    assert_match "reelabs-mcp", shell_output("#{bin}/reelabs-mcp --help")
  end
end
