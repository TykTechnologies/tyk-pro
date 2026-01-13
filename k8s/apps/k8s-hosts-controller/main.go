package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/go-logr/logr"
	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	"github.com/TykTechnologies/k8s-hosts-controller/pkg/controller"
	"github.com/TykTechnologies/k8s-hosts-controller/pkg/hosts"
)

var scheme = runtime.NewScheme()

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(networkingv1.AddToScheme(scheme))
}

type Config struct {
	Namespaces    []string
	AllNamespaces bool
	HostsFile     string
	Marker        string
	Cleanup       bool
	Verbose       bool
}

func parseFlags() Config {
	var (
		namespaces    string
		allNamespaces bool
		hostsFile     string
		marker        string
		cleanup       bool
		verbose       bool
	)

	flag.StringVar(&namespaces, "namespaces", "", "Comma-separated namespaces to watch")
	flag.BoolVar(&allNamespaces, "all-namespaces", false, "Watch all namespaces")
	flag.StringVar(&hostsFile, "hosts-file", "/etc/hosts", "Path to hosts file")
	flag.StringVar(&marker, "marker", "TYK-K8S-HOSTS", "Marker for managed entries")
	flag.BoolVar(&cleanup, "cleanup", false, "Remove all managed entries and exit")
	flag.BoolVar(&verbose, "verbose", false, "Enable verbose logging")
	flag.Parse()

	var nsList []string
	if namespaces != "" {
		for _, ns := range strings.Split(namespaces, ",") {
			ns = strings.TrimSpace(ns)
			if ns != "" {
				nsList = append(nsList, ns)
			}
		}
	}

	return Config{
		Namespaces:    nsList,
		AllNamespaces: allNamespaces,
		HostsFile:     hostsFile,
		Marker:        marker,
		Cleanup:       cleanup,
		Verbose:       verbose,
	}
}

func run(ctx context.Context, cfg Config) error {
	log := ctrl.Log.WithName("setup")

	hostsManager := hosts.NewManager(cfg.HostsFile, cfg.Marker)

	if cfg.Cleanup {
		if err := hostsManager.Cleanup(ctx); err != nil {
			return fmt.Errorf("failed to cleanup hosts file: %w", err)
		}
		log.Info("Cleaned up hosts file")
		return nil
	}

	if !cfg.AllNamespaces && len(cfg.Namespaces) == 0 {
		return errors.New("either --namespaces or --all-namespaces must be specified")
	}

	gracefulShutdown := 30 * time.Second
	opts := ctrl.Options{
		Scheme: scheme,
		Metrics: metricsserver.Options{
			BindAddress: "0",
		},
		GracefulShutdownTimeout: &gracefulShutdown,
	}

	if !cfg.AllNamespaces {
		log.Info("Watching namespaces", "namespaces", cfg.Namespaces)

		nsMap := make(map[string]cache.Config, len(cfg.Namespaces))
		for _, ns := range cfg.Namespaces {
			nsMap[ns] = cache.Config{}
		}
		opts.Cache = cache.Options{
			DefaultNamespaces: nsMap,
		}
	} else {
		log.Info("Watching all namespaces")
	}

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), opts)
	if err != nil {
		return fmt.Errorf("unable to create manager: %w", err)
	}

	reconciler := controller.NewIngressReconciler(mgr.GetClient(), hostsManager)
	if err := reconciler.SetupWithManager(mgr); err != nil {
		return fmt.Errorf("unable to create controller: %w", err)
	}

	err = mgr.Add(&cleanupRunnable{hostsManager: hostsManager, log: log})
	if err != nil {
		return fmt.Errorf("unable to add cleanup runnable: %w", err)
	}

	log.Info("Starting controller")
	if err := mgr.Start(ctx); err != nil {
		return fmt.Errorf("problem running manager: %w", err)
	}

	return nil
}

// cleanupRunnable implements manager.Runnable to ensure cleanup happens
// after manager shutdown completes (all reconcilers drained).
type cleanupRunnable struct {
	hostsManager *hosts.Manager
	log          logr.Logger
}

func (c *cleanupRunnable) Start(ctx context.Context) error {
	// Wait for context cancellation (shutdown signal)
	<-ctx.Done()

	// Small delay to ensure all reconcilers have finished
	// The manager's GracefulShutdownTimeout handles the actual draining
	c.log.Info("Shutting down, cleaning up hosts entries...")

	// Use a new context for cleanup since the original is cancelled
	cleanupCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := c.hostsManager.Cleanup(cleanupCtx); err != nil {
		c.log.Error(err, "Failed to cleanup hosts file on shutdown")
		// Don't return error - we want shutdown to complete
	}

	return nil
}

func main() {
	cfg := parseFlags()

	ctrl.SetLogger(zap.New(zap.UseDevMode(cfg.Verbose)))
	log := ctrl.Log.WithName("main")

	ctx := ctrl.SetupSignalHandler()

	if err := run(ctx, cfg); err != nil {
		log.Error(err, "Controller failed")
		os.Exit(1)
	}
}
