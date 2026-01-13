#!/usr/bin/env python3
"""
tyk-toxiproxy CLI - Dynamic Toxiproxy configuration for Tyk K8s resilience testing.

Usage:
    python cli.py configure --toxiproxy-url http://localhost:8474 --output-env shell
"""

import time
from dataclasses import dataclass, field
from typing import Optional
from urllib.parse import urlparse

import typer
from discovery import ControlPlaneInfo, DataPlaneInfo, K8sDiscovery
from rich.console import Console
from toxiproxy import Toxiproxy

app = typer.Typer(
    name="tyk-toxiproxy",
    help="Dynamic Toxiproxy configuration for Tyk K8s resilience testing.",
    no_args_is_help=True,
    add_completion=False,
)
configure_app = typer.Typer()
app.add_typer(configure_app, name="configure")

console = Console()
err_console = Console(stderr=True)


@dataclass
class ProxyConfig:
    name: str
    listen: str
    upstream: str
    enabled: bool = True

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "listen": self.listen,
            "upstream": self.upstream,
            "enabled": self.enabled,
        }


@dataclass
class ToxiproxyConfig:
    proxies: list[ProxyConfig] = field(default_factory=list)

    def to_list(self) -> list[dict]:
        return [p.to_dict() for p in self.proxies]

    def get_port_mappings(self) -> list[tuple[str, int]]:
        result = []
        for proxy in self.proxies:
            port = int(proxy.listen.split(":")[-1])
            result.append((proxy.name, port))
        return result


BASE_REDIS_DP_PORT = 7379


def build_proxy_config(
    cp: ControlPlaneInfo, data_planes: list[DataPlaneInfo]
) -> ToxiproxyConfig:
    proxies = []

    if cp.dashboard:
        proxies.append(
            ProxyConfig(
                name="dashboard", listen="[::]:3000", upstream=cp.dashboard.address
            )
        )
    if cp.gateway:
        proxies.append(
            ProxyConfig(
                name="cp-gateway", listen="[::]:8080", upstream=cp.gateway.address
            )
        )
    if cp.mdcb:
        proxies.append(
            ProxyConfig(name="mdcb", listen="[::]:9091", upstream=cp.mdcb.address)
        )
    if cp.redis:
        proxies.append(
            ProxyConfig(name="redis-cp", listen="[::]:6379", upstream=cp.redis.address)
        )
    if cp.mongo:
        proxies.append(
            ProxyConfig(name="mongo", listen="[::]:27017", upstream=cp.mongo.address)
        )

    for dp in data_planes:
        if dp.redis:
            port = BASE_REDIS_DP_PORT + (dp.index * 1000)
            proxies.append(
                ProxyConfig(
                    name=f"redis-dp-{dp.index}",
                    listen=f"[::]:{port}",
                    upstream=dp.redis.address,
                )
            )

    return ToxiproxyConfig(proxies=proxies)


def generate_env_vars(
    toxiproxy_url: str, data_planes: list[DataPlaneInfo]
) -> dict[str, str]:
    env_vars = {
        "TOXIPROXY_URL": toxiproxy_url,
        "TYK_TEST_BASE_URL": "http://chart-dash.test/",
        "TYK_TEST_GW_URL": "http://chart-gw.test/",
        "TYK_TEST_GW_SECRET": "352d20ee67be67f6340b4c0605b044b7",
    }
    for dp in data_planes:
        env_vars[f"TYK_TEST_GW_{dp.index}_ALFA_URL"] = (
            f"http://chart-gw-dp-{dp.index}.test/"
        )
    return env_vars


def generate_hosts_entries(data_planes: list[DataPlaneInfo]) -> list[str]:
    entries = [
        "127.0.0.1 chart-dash.test",
        "127.0.0.1 chart-gw.test",
        "127.0.0.1 chart-mdcb.test",
    ]
    for dp in data_planes:
        entries.append(f"127.0.0.1 chart-gw-dp-{dp.index}.test")
    return entries


def format_shell_env(env_vars: dict[str, str]) -> str:
    return "\n".join(f'export {k}="{v}"' for k, v in sorted(env_vars.items()))


def format_github_actions_env(env_vars: dict[str, str]) -> str:
    return "\n".join(f"{k}={v}" for k, v in sorted(env_vars.items()))


def create_toxiproxy_client(url: str) -> Toxiproxy:
    parsed = urlparse(url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 8474
    client = Toxiproxy()
    client.update_api_consumer(host, port)
    return client


def wait_for_toxiproxy(client: Toxiproxy, timeout: int = 30) -> bool:
    start = time.time()
    while time.time() - start < timeout:
        try:
            if client.running():
                return True
        except Exception:
            pass
        time.sleep(1)
    return False


@configure_app.callback(invoke_without_command=True)
def configure(
    toxiproxy_url: str = typer.Option(
        "http://localhost:8474",
        "--toxiproxy-url",
        "-t",
        help="Toxiproxy API URL",
    ),
    namespace_pattern: str = typer.Option(
        "tyk-dp-*",
        "--namespace-pattern",
        "-n",
        help="Glob pattern for data plane namespaces",
    ),
    control_namespace: str = typer.Option(
        "tyk",
        "--control-namespace",
        "-c",
        help="Control plane namespace",
    ),
    output_env: Optional[str] = typer.Option(
        None,
        "--output-env",
        "-o",
        help="Output format: shell, github-actions",
    ),
    output_hosts: bool = typer.Option(
        False,
        "--output-hosts",
        help="Output /etc/hosts entries only",
    ),
    verbose: bool = typer.Option(
        False,
        "--verbose",
        "-v",
        help="Enable verbose output",
    ),
):
    try:
        if verbose:
            err_console.print("[blue]Discovering Kubernetes services...[/blue]")

        discovery = K8sDiscovery()
        control_plane = discovery.discover_control_plane(control_namespace)
        data_planes = discovery.discover_data_planes(namespace_pattern)

        if verbose:
            err_console.print(f"[green]Found {len(data_planes)} data plane(s)[/green]")

        config = build_proxy_config(control_plane, data_planes)

        if output_hosts:
            console.print("\n".join(generate_hosts_entries(data_planes)))
            return

        if verbose:
            err_console.print(
                f"[blue]Connecting to toxiproxy at {toxiproxy_url}...[/blue]"
            )

        client = create_toxiproxy_client(toxiproxy_url)
        if not wait_for_toxiproxy(client):
            err_console.print("[red]ERROR: Toxiproxy not ready[/red]")
            raise typer.Exit(1)

        if verbose:
            err_console.print(
                f"[green]Connected to toxiproxy {client.version()}[/green]"
            )

        client.populate(config.to_list())

        if verbose:
            err_console.print(
                f"[green]Configured {len(config.proxies)} proxies[/green]"
            )

        try:
            discovery.patch_toxiproxy_service(
                namespace=control_namespace,
                service_name="toxiproxy",
                proxy_ports=config.get_port_mappings(),
            )
        except Exception as e:
            if verbose:
                err_console.print(
                    f"[yellow]Warning: Failed to patch Service: {e}[/yellow]"
                )

        if output_env:
            env_vars = generate_env_vars(toxiproxy_url, data_planes)
            if output_env == "shell":
                # Use standard print for reliable stdout redirection in CI
                print(format_shell_env(env_vars), flush=True)
            elif output_env == "github-actions":
                # Use standard print for reliable stdout redirection in CI
                print(format_github_actions_env(env_vars), flush=True)
            else:
                err_console.print(f"[red]Unknown format: {output_env}[/red]")
                raise typer.Exit(1)

    except Exception as e:
        err_console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1)


if __name__ == "__main__":
    app()
