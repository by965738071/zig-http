use clap::Parser;
use futures::StreamExt;
use std::time::{Duration, Instant};
use tokio::net::TcpStream;

#[derive(Parser, Debug, Clone)]
#[command(author, version, about, long_about = None)]
struct Config {
    /// 目标 IP 地址
    #[arg(short = 'i', long = "ip", default_value = "127.0.0.1")]
    ip: String,

    /// 起始端口
    #[arg(short = 's', long = "start", default_value_t = 1)]
    start_port: u16,

    /// 结束端口
    #[arg(short = 'e', long = "end", default_value_t = 65535)]
    end_port: u16,

    /// 并发数
    #[arg(short = 'c', long = "concurrency", default_value_t = 25000)]
    concurrency: usize,

    /// 超时时间（毫秒）
    #[arg(short = 't', long = "timeout", default_value_t = 200)]
    timeout: u64,
}

#[tokio::main]
async fn main() {
    let args = Config::parse();
    let start = Instant::now();

    // 使用缓冲流控制并发
    let mut result: Vec<_> = futures::stream::iter(args.start_port..=args.end_port)
        .map(|port| {
            let host_port = format!("{}:{}", args.ip, port);
            async move {
                if let Ok(Ok(_)) = tokio::time::timeout(
                    Duration::from_millis(args.timeout),
                    TcpStream::connect(host_port),
                )
                .await
                {
                    Some(port)
                } else {
                    None
                }
            }
        })
        .buffer_unordered(args.concurrency) // 最大并发数
        .filter_map(|port| async move { port })
        .collect()
        .await;

    result.sort();

    let count = result.len();
    print!("Open ports ({count} found):\n");

    result.into_iter().for_each(|port| print!("  {port}\n"));
    println!("Execution Time: {:?}", start.elapsed());
}