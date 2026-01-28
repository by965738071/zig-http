package main

import (
        "bufio"
        "flag"
        "fmt"
        "net"
        "os"
        "sort"
        "sync"
        "time"
)

// Config 存储命令行参数
type Config struct {
    Target       string        // 目标 IP 地址
    Concurrency  int           // 并发数
    StartPort    int           // 起始端口
    EndPort      int           // 结束端口
    Timeout      time.Duration // 超时时间
}

func parseFlags() Config {
    var config Config

    // 定义命令行参数
    flag.StringVar(&config.Target, "ip", "127.0.0.1", "目标 IP 地址")
    flag.IntVar(&config.Concurrency, "con", 100, "并发数")
    flag.IntVar(&config.StartPort, "begin", 1, "起始端口")
    flag.IntVar(&config.EndPort, "end", 65535, "结束端口")
    timeout := flag.Int("to", 1, "超时时间（秒）")

    // 参数生效
    flag.Parse()

    // 将超时秒数转换为 Duration
    config.Timeout = time.Duration(*timeout) * time.Second

    return config
}

func measureTime(fn func()) {
    start := time.Now()
    fn()
    elapsed := time.Since(start)
        fmt.Printf("Execution Time: %v\n", elapsed)
}

var config = parseFlags()

func worker(ports <-chan int, results chan<- int) {
        var wg sync.WaitGroup

        // 创建指定数量的 worker
        for range config.Concurrency {
                wg.Go(func() {
                        for port := range ports {
                                addr := net.JoinHostPort(config.Target, fmt.Sprintf("%d", port))
                                conn, err := net.DialTimeout("tcp", addr, config.Timeout)
                                if err != nil {
                                        continue
                                }
                                conn.Close()
                                results <- port
                        }
                })
        }
        wg.Wait()
        close(results)
}

func tcpScan() {
        ports := make(chan int, config.Concurrency)
        results := make(chan int, config.Concurrency)

        // 发送端口到 ports channel
        go func() {
                for i := config.StartPort; i <= config.EndPort; i++ {
                        ports <- i
                }
                close(ports)
        }()

        // 启动 worker
        go worker(ports, results)
        fmt.Printf("Scanning %s\n", config.Target)

        // 收集结果
        opened := []int{}
        for port := range results {
                opened = append(opened, port)
        }

        // 排序
    sort.Ints(opened)

        // 打印结果
        fmt.Printf("Open ports (%d found):\n", len(opened))
        for _, port := range opened {
                fmt.Printf("  %d\n", port)
        }
}

func main() {
    measureTime(tcpScan)
    waitEnter()
}

// 按回车键退出程序
func waitEnter() {
        scanner := bufio.NewScanner(os.Stdin)
        for scanner.Scan() {
                line := scanner.Text()
                if len(line) == 0 {
                        break
                }
        }
}