package controller

import (
	"context"
	"time"

	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/predicate"

	"github.com/TykTechnologies/k8s-hosts-controller/pkg/hosts"
)

const (
	// requeueDelayNoIP is the delay before requeuing when no LoadBalancer IP is available.
	requeueDelayNoIP = 30 * time.Second
)

// IngressReconciler reconciles Ingress objects.
type IngressReconciler struct {
	client       client.Client
	hostsManager *hosts.Manager
}

// NewIngressReconciler creates a new IngressReconciler.
func NewIngressReconciler(c client.Client, hostsManager *hosts.Manager) *IngressReconciler {
	return &IngressReconciler{
		client:       c,
		hostsManager: hostsManager,
	}
}

// Reconcile handles Ingress events.
func (r *IngressReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := log.FromContext(ctx).WithValues("ingress", req.NamespacedName.String())

	ingress := &networkingv1.Ingress{}

	err := r.client.Get(ctx, req.NamespacedName, ingress)
	if err != nil {
		if errors.IsNotFound(err) {
			log.Info("Ingress seems to be deleted, removing hosts entries")
			if err := r.hostsManager.RemoveIngress(ctx, req.NamespacedName.String()); err != nil {
				return ctrl.Result{}, err
			}

			return ctrl.Result{}, nil
		}

		return ctrl.Result{}, err
	}

	hostnames := extractHostnames(ingress)
	if len(hostnames) == 0 {
		log.Info("Ingress has no hostnames", "ingress", req.NamespacedName)
		if err := r.hostsManager.RemoveIngress(ctx, req.NamespacedName.String()); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{}, nil
	}

	ip := extractLoadBalancerIP(ingress)
	if ip == "" {
		log.Info("Ingress has no LoadBalancer IP yet, will requeue", "requeueAfter", requeueDelayNoIP)
		return ctrl.Result{RequeueAfter: requeueDelayNoIP}, nil
	}

	log.Info("Updating hosts entries", "lbIp", ip, "hostnames", hostnames)

	err = r.hostsManager.UpdateIngress(ctx, req.NamespacedName.String(), ip, hostnames)
	if err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}

// SetupWithManager sets up the controller with the Manager.
func (r *IngressReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&networkingv1.Ingress{}).
		WithEventFilter(r.eventFilter()).
		Complete(r)
}

// eventFilter returns a predicate that filters events to reduce unnecessary reconciliations.
func (r *IngressReconciler) eventFilter() predicate.Predicate {
	return predicate.Funcs{
		CreateFunc: func(e event.CreateEvent) bool {
			return true
		},
		UpdateFunc: func(e event.UpdateEvent) bool {
			oldIngress, ok := e.ObjectOld.(*networkingv1.Ingress)
			if !ok {
				return true
			}
			newIngress, ok := e.ObjectNew.(*networkingv1.Ingress)
			if !ok {
				return true
			}

			return hostsRelevantFieldsChanged(oldIngress, newIngress)
		},
		DeleteFunc: func(e event.DeleteEvent) bool {
			return true
		},
		GenericFunc: func(e event.GenericEvent) bool {
			return true
		},
	}
}

// hostsRelevantFieldsChanged returns true if fields relevant to hosts file have changed.
func hostsRelevantFieldsChanged(old, new *networkingv1.Ingress) bool {
	oldIP := extractLoadBalancerIP(old)
	newIP := extractLoadBalancerIP(new)
	if oldIP != newIP {
		return true
	}

	oldHostnames := extractHostnames(old)
	newHostnames := extractHostnames(new)

	if len(oldHostnames) != len(newHostnames) {
		return true
	}

	oldSet := make(map[string]struct{}, len(oldHostnames))
	for _, h := range oldHostnames {
		oldSet[h] = struct{}{}
	}

	for _, h := range newHostnames {
		if _, exists := oldSet[h]; !exists {
			return true
		}
	}

	return false
}

// extractLoadBalancerIP gets the first IP from Ingress status.
// Returns empty string if no IP is available.
func extractLoadBalancerIP(ingress *networkingv1.Ingress) string {
	if ingress == nil {
		return ""
	}

	for _, ing := range ingress.Status.LoadBalancer.Ingress {
		if ing.IP != "" {
			return ing.IP
		}
		// Some providers use hostname instead of IP (e.g., AWS ELB)
		// For /etc/hosts we need an IP, so skip hostnames
	}

	return ""
}

// extractHostnames gets all unique hostnames from Ingress rules.
func extractHostnames(ingress *networkingv1.Ingress) []string {
	if ingress == nil {
		return nil
	}

	var hostnames []string
	seen := make(map[string]struct{})

	for _, rule := range ingress.Spec.Rules {
		if rule.Host != "" {
			if _, exists := seen[rule.Host]; !exists {
				hostnames = append(hostnames, rule.Host)
				seen[rule.Host] = struct{}{}
			}
		}
	}

	return hostnames
}
