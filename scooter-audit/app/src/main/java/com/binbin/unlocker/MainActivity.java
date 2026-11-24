package com.binbin.unlocker;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanResult;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.*;
import java.util.*;

public class MainActivity extends Activity {
    private BluetoothAdapter adapter;
    private BluetoothLeScanner scanner;
    private BluetoothGatt gatt;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final List<BluetoothDevice> devices = new ArrayList<>();
    private final List<String> rows = new ArrayList<>();
    private ArrayAdapter<String> listAdapter;
    private TextView status, details;
    private Button scanButton, inspectButton, testButton;
    private boolean testRunning = false;
    private int testSeconds = 10;
    private final Runnable testTicker = new Runnable() {
        @Override public void run() {
            if (!testRunning) return;
            if (testSeconds > 0) {
                testButton.setText("UNLOCK TEST · " + testSeconds + "s");
                status.setText("SIMULATION ONLY — test window: " + testSeconds + " seconds. Scooter control commands are not sent.");
                testSeconds--;
                handler.postDelayed(this, 1000);
            } else {
                testRunning = false;
                testButton.setText("UNLOCK TEST · 10s");
                status.setText("LOCKED — simulation complete. No physical scooter state was changed.");
                details.append("\n\n10-SECOND UI SIMULATION COMPLETE. No BLE write or unlock/lock command was transmitted.");
            }
        }
    };
    private BluetoothDevice selected;
    private boolean scanning = false;

    private final ScanCallback scanCallback = new ScanCallback() {
        @Override public void onScanResult(int callbackType, ScanResult result) {
            BluetoothDevice d = result.getDevice();
            String address;
            String name;
            try {
                address = d.getAddress();
                name = d.getName();
            } catch (SecurityException e) { return; }
            if (address == null) return;
            for (BluetoothDevice existing : devices) {
                try { if (address.equals(existing.getAddress())) return; }
                catch (SecurityException ignored) { return; }
            }
            devices.add(d);
            String label = (name == null || name.isEmpty() ? "Unnamed BLE device" : name)
                    + "\n" + address + "   •   RSSI " + result.getRssi() + " dBm";
            rows.add(label);
            listAdapter.notifyDataSetChanged();
        }
        @Override public void onScanFailed(int errorCode) {
            scanning = false;
            status.setText("Scan failed (code " + errorCode + "). Check Bluetooth and permissions.");
        }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        buildUi();
        BluetoothManager manager = (BluetoothManager) getSystemService(BLUETOOTH_SERVICE);
        adapter = manager == null ? null : manager.getAdapter();
        requestNeededPermissions();
    }

    private void buildUi() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(24, 28, 24, 16);
        root.setBackgroundColor(0xFF101318);

        TextView title = new TextView(this);
        title.setText("SCOOTER AUDIT");
        title.setTextColor(0xFFFFD54F);
        title.setTextSize(25);
        title.setTypeface(null, 1);
        root.addView(title);

        TextView subtitle = new TextView(this);
        subtitle.setText("Read-only Bluetooth security inspection");
        subtitle.setTextColor(0xFFB8C0CC);
        subtitle.setPadding(0, 4, 0, 16);
        root.addView(subtitle);

        status = new TextView(this);
        status.setText("Grant Bluetooth permissions, then scan.");
        status.setTextColor(0xFFFFFFFF);
        status.setPadding(0, 8, 0, 12);
        root.addView(status);

        scanButton = new Button(this);
        scanButton.setText("SCAN NEARBY DEVICES");
        root.addView(scanButton);

        ListView list = new ListView(this);
        listAdapter = new ArrayAdapter<String>(this, android.R.layout.simple_list_item_1, rows) {
            @Override public View getView(int position, View convertView, android.view.ViewGroup parent) {
                View v = super.getView(position, convertView, parent);
                ((TextView)v).setTextColor(0xFFFFFFFF);
                v.setBackgroundColor(0xFF202630);
                return v;
            }
        };
        list.setAdapter(listAdapter);
        root.addView(list, new LinearLayout.LayoutParams(-1, 0, 1));

        inspectButton = new Button(this);
        inspectButton.setText("INSPECT SELECTED DEVICE");
        inspectButton.setEnabled(false);
        root.addView(inspectButton);

        details = new TextView(this);
        details.setTextColor(0xFFE0E5EC);
        details.setTextSize(12);
        details.setPadding(0, 12, 0, 8);
        ScrollView scroll = new ScrollView(this);
        scroll.addView(details);
        root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));

        setContentView(root);
        scanButton.setOnClickListener(v -> startScan());
        list.setOnItemClickListener((p, v, pos, id) -> {
            if (pos < devices.size()) {
                selected = devices.get(pos);
                inspectButton.setEnabled(true);
                status.setText("Selected device. Inspection is read-only.");
            }
        });
        inspectButton.setOnClickListener(v -> inspectSelected());\n        testButton.setOnClickListener(v -> startTenSecondSimulation());
    }

    private void startTenSecondSimulation() {\n        if (testRunning) {\n            testRunning = false;\n            handler.removeCallbacks(testTicker);\n            testButton.setText("UNLOCK TEST · 10s (SIMULATION)");\n            status.setText("Simulation cancelled. No scooter command was sent.");\n            return;\n        }\n        testRunning = true;\n        testSeconds = 10;\n        details.append("\\n\\nStarting 10-second interface simulation. This is not a real unlock test.");\n        handler.removeCallbacks(testTicker);\n        handler.post(testTicker);\n    }\n\n    private void requestNeededPermissions() {
        ArrayList<String> needed = new ArrayList<>();
        if (Build.VERSION.SDK_INT >= 31) {
            if (checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED)
                needed.add(Manifest.permission.BLUETOOTH_SCAN);
            if (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED)
                needed.add(Manifest.permission.BLUETOOTH_CONNECT);
        } else if (Build.VERSION.SDK_INT >= 23 &&
                checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            needed.add(Manifest.permission.ACCESS_FINE_LOCATION);
        }
        if (!needed.isEmpty()) requestPermissions(needed.toArray(new String[0]), 7);
    }

    private boolean hasPermissions() {
        if (Build.VERSION.SDK_INT >= 31)
            return checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
                    && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED;
        return Build.VERSION.SDK_INT < 23 ||
                checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    private void startScan() {
        if (!hasPermissions()) { requestNeededPermissions(); status.setText("Bluetooth permissions are required."); return; }
        if (adapter == null || !adapter.isEnabled()) { status.setText("Turn Bluetooth on first."); return; }
        if (scanning) return;
        scanner = adapter.getBluetoothLeScanner();
        if (scanner == null) { status.setText("BLE scanner unavailable."); return; }
        devices.clear(); rows.clear(); listAdapter.notifyDataSetChanged();
        details.setText("");
        scanning = true;
        status.setText("Scanning for 12 seconds…");
        try {
            scanner.startScan(scanCallback);
            handler.postDelayed(() -> {
                if (scanning) {
                    try { scanner.stopScan(scanCallback); } catch (SecurityException ignored) {}
                    scanning = false;
                    status.setText("Scan complete. Found " + devices.size() + " BLE device(s).");
                }
            }, 12000);
        } catch (SecurityException e) {
            scanning = false;
            status.setText("Permission denied. Allow Nearby devices access.");
        }
    }

    private void inspectSelected() {
        if (selected == null || !hasPermissions()) return;
        if (gatt != null) { try { gatt.close(); } catch (Exception ignored) {} gatt = null; }
        details.setText("Connecting to selected device to enumerate advertised GATT services…\n");
        status.setText("Connecting (read-only inspection)…");
        try {
            gatt = selected.connectGatt(this, false, new BluetoothGattCallback() {
                @Override public void onConnectionStateChange(BluetoothGatt g, int statusCode, int newState) {
                    runOnUiThread(() -> {
                        if (newState == android.bluetooth.BluetoothProfile.STATE_CONNECTED) {
                            status.setText("Connected. Discovering services…");
                            g.discoverServices();
                        } else if (newState == android.bluetooth.BluetoothProfile.STATE_DISCONNECTED) {
                            status.setText("Disconnected.");
                        }
                    });
                }
                @Override public void onServicesDiscovered(BluetoothGatt g, int statusCode) {
                    StringBuilder report = new StringBuilder();
                    report.append("READ-ONLY DEVICE INSPECTION\n");
                    report.append("GATT status: ").append(statusCode).append("\n");
                    if (statusCode == BluetoothGatt.GATT_SUCCESS) {
                        for (BluetoothGattService service : g.getServices()) {
                            report.append("\nSERVICE  ").append(service.getUuid()).append("\n");
                            for (BluetoothGattCharacteristic c : service.getCharacteristics()) {
                                int p = c.getProperties();
                                report.append("  CHARACTERISTIC  ").append(c.getUuid()).append("\n");
                                report.append("  Properties: ").append(propertyNames(p)).append("\n");
                            }
                        }
                        if (g.getServices().isEmpty()) report.append("No GATT services returned.\n");
                    } else report.append("Service discovery failed; status is not a security verdict.\n");
                    report.append("\nLIMITATION: Advertising and GATT metadata do not prove whether remote unlock is possible. This app sends no write, unlock, replay, or control commands.");
                    String output = report.toString();
                    runOnUiThread(() -> {
                        details.setText(output);
                        status.setText("Inspection finished. Review the limitations in the report.");
                    });
                }
            }, BluetoothDevice.TRANSPORT_LE);
        } catch (SecurityException e) {
            status.setText("Bluetooth permission denied.");
        }
    }

    private String propertyNames(int p) {
        ArrayList<String> names = new ArrayList<>();
        if ((p & BluetoothGattCharacteristic.PROPERTY_READ) != 0) names.add("READ");
        if ((p & BluetoothGattCharacteristic.PROPERTY_WRITE) != 0) names.add("WRITE");
        if ((p & BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0) names.add("WRITE_NO_RESPONSE");
        if ((p & BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0) names.add("NOTIFY");
        if ((p & BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0) names.add("INDICATE");
        if ((p & BluetoothGattCharacteristic.PROPERTY_SIGNED_WRITE) != 0) names.add("SIGNED_WRITE");
        return names.isEmpty() ? "NONE" : android.text.TextUtils.join(", ", names);
    }

    @Override protected void onDestroy() {
        super.onDestroy();
        if (scanner != null && scanning) {
            try { scanner.stopScan(scanCallback); } catch (Exception ignored) {}
        }
        if (gatt != null) { try { gatt.disconnect(); gatt.close(); } catch (Exception ignored) {} }
        testRunning = false;\n        handler.removeCallbacksAndMessages(null);
    }
}
