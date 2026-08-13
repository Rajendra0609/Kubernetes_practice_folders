#!/bin/bash

# Ensure a namespace is provided, or default to all namespaces
NAMESPACE="${1:- --all-namespaces}"

echo "========================================================================"
echo "🔍 STARTING TRUGE: STUCK TERMINATING PODS"
echo "========================================================================"

# Fetch all terminating pods
TERMINATING_PODS=$(kubectl get pods $NAMESPACE -o json | jq -c '.items[] | select(.metadata.deletionTimestamp != null)')

if [ -z "$TERMINATING_PODS" ]; then
    echo "✅ No terminating pods found. Cluster looks healthy!"
    exit 0
fi

echo "$TERMINATING_PODS" | while read -r pod; do
    POD_NAME=$(echo "$pod" | jq -r '.metadata.name')
    POD_NS=$(echo "$pod" | jq -r '.metadata.namespace')
    NODE_NAME=$(echo "$pod" | jq -r '.spec.nodeName')
    
    echo -e "\n------------------------------------------------------------------------"
    echo "📋 Evaluating Pod: [$POD_NS/$POD_NAME] on Node: [$NODE_NAME]"
    echo "------------------------------------------------------------------------"

    # Handle cases where the pod hasn't even been assigned to a node yet
    if [ "$NODE_NAME" == "null" ] || [ -z "$NODE_NAME" ]; then
        echo "⚠️ Pod was never scheduled to a node. Safe to force delete."
        echo "💡 Action: kubectl delete pod $POD_NAME -n $POD_NS --force --grace-period=0"
        continue
    fi

    # 1. Is the Node Healthy?
    NODE_STATUS=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    
    if [ "$NODE_STATUS" == "True" ]; then
        echo "🌿 Path: [Is Node Healthy? -> YES]"
        echo "   ↳ Checking Finalizers and Grace Periods..."
        
        # Check for active finalizers
        FINALIZERS=$(echo "$pod" | jq -r '.metadata.finalizers[]?')
        if [ ! -z "$FINALIZERS" ]; then
            echo "   ⚠️ Found active finalizers blocking deletion:"
            echo "$FINALIZERS" | sed 's/^/     - /'
        fi
        
        # Check grace period expiration
        DEL_TIME=$(echo "$pod" | jq -r '.metadata.deletionTimestamp')
        GRACE_SEC=$(echo "$pod" | jq -r '.metadata.deletionGracePeriodSeconds')
        echo "   ⏱️ Deletion initiated at: $DEL_TIME (Grace Period: ${GRACE_SEC}s)"
        echo "   💡 Action: Node is healthy. API server lag or a stuck preStop hook/finalizer is likely."
        echo "      Verify application logs, or clear finalizers if safe:"
        echo "      kubectl patch pod $POD_NAME -n $POD_NS --type json -p='[{\"op\": \"remove\", \"path\": \"/metadata/finalizers\"}]'"

    else
        echo "🛑 Path: [Is Node Healthy? -> NO (Status: $NODE_STATUS)]"
        echo "   ↳ Checking if storage volumes are attached elsewhere..."

        # 2. Check Volume Attachments to look for Multi-Attach conflicts
        # Find claims used by this pod
        PVC_NAMES=$(echo "$pod" | jq -r '.spec.volumes[]? | .persistentVolumeClaim.claimName' | grep -v '^null$')
        
        if [ -z "$PVC_NAMES" ]; then
            echo "   ✅ Pod does not use any Persistent Volume Claims."
            echo "   💡 Action: [Safe to Force Delete]"
            echo "      kubectl delete pod $POD_NAME -n $POD_NS --force --grace-period=0"
        else
            echo "   📦 Pod utilizes PVCs: $(echo "$PVC_NAMES" | xargs)"
            
            MULTI_ATTACH_RISK=false
            for pvc in $PVC_NAMES; do
                # Get the underlying PV name
                PV_NAME=$(kubectl get pvc "$pvc" -n "$POD_NS" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
                if [ ! -z "$PV_NAME" ]; then
                    # Scan VolumeAttachment objects for this specific PV
                    ATTACHMENTS=$(kubectl get volumeattachments -o json | jq -r --arg pv "$PV_NAME" '.items[] | select(.spec.source.persistentVolumeName == $pv) | "\(.spec.nodeName) (Attached: \(.status.attached))"')
                    
                    if [ ! -z "$ATTACHMENTS" ]; then
                        echo "   ⚠️ VolumeAttachment found for $PV_NAME:"
                        echo "$ATTACHMENTS" | sed 's/^/     - Node: /'
                        
                        # If attached to a different node, or multiple nodes exist
                        ATTACH_COUNT=$(echo "$ATTACHMENTS" | wc -l)
                        if [ "$ATTACH_COUNT" -gt 1 ] || [[ "$ATTACHMENTS" != *"$NODE_NAME"* ]]; then
                            MULTI_ATTACH_RISK=true
                        fi
                    fi
                fi
            done

            if [ "$MULTI_ATTACH_RISK" == "true" ]; then
                echo "   🚨 Path: [Is storage attached elsewhere? -> YES]"
                echo "   🔥 CRITICAL RISK: Multi-Attach / Split-Brain Error Detected!"
                echo "   ⛔ DO NOT force delete yet. Ensure the source node ($NODE_NAME) is explicitly fenced/powered off first."
            else
                echo "   🟢 Path: [Is storage attached elsewhere? -> NO]"
                echo "   💡 Action: [Safe to Force Delete]"
                echo "      Node is dead and volumes are not multi-attached. Clear the pod to release claims:"
                echo "      kubectl delete pod $POD_NAME -n $POD_NS --force --grace-period=0"
            fi
        fi
    fi
done
