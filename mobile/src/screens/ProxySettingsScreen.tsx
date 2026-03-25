
import React, { useState, useEffect } from 'react';
import { View, Text, TextInput, TouchableOpacity, FlatList, StyleSheet, Alert } from 'react-native';
import ProxyManager, { ServerEndpoint } from '../lib/ProxyManager';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft, Check, Plus } from 'lucide-react-native';

export default function ProxySettingsScreen({ navigation }: any) {
    const [url, setUrl] = useState('');
    const [endpoints, setEndpoints] = useState<ServerEndpoint[]>([]);
    const [current, setCurrent] = useState<ServerEndpoint | null>(null);
    const proxy = ProxyManager.getInstance();

    useEffect(() => {
        load();
        const unsub = proxy.subscribe(() => load());
        return unsub;
    }, []);

    const load = () => {
        setEndpoints(proxy.getEndpoints());
        setCurrent(proxy.getCurrentEndpoint());
    };

    const handleAdd = async () => {
        if (!url) return;
        try {
            await proxy.addEndpoint(url, 'Custom Server');
            await proxy.setPrimaryEndpoint(url);
            setUrl('');
            Alert.alert('Success', 'Server added and set as primary');
        } catch (e) {
            Alert.alert('Error', 'Invalid URL');
        }
    };

    return (
        <SafeAreaView style={styles.container}>
            <View style={styles.header}>
                <TouchableOpacity onPress={() => navigation.goBack()}>
                    <ArrowLeft color="#fff" size={24} />
                </TouchableOpacity>
                <Text style={styles.title}>Proxy Settings</Text>
            </View>

            <Text style={styles.desc}>
                If the main server is blocked, enter a custom proxy URL here.
            </Text>

            <View style={styles.inputContainer}>
                <TextInput
                    style={styles.input}
                    placeholder="https://api.vibegram.io"
                    placeholderTextColor="#666"
                    value={url}
                    autoCapitalize="none"
                    onChangeText={setUrl}
                />
                <TouchableOpacity style={styles.addBtn} onPress={handleAdd}>
                    <Plus color="#000" size={24} />
                </TouchableOpacity>
            </View>

            <FlatList
                data={endpoints}
                keyExtractor={item => item.url}
                renderItem={({ item }) => (
                    <TouchableOpacity
                        style={[styles.item, current?.url === item.url && styles.activeItem]}
                        onPress={() => proxy.setPrimaryEndpoint(item.url)}
                    >
                        <View>
                            <Text style={styles.itemUrl}>{item.url}</Text>
                            <Text style={styles.itemStatus}>Status: {item.status}</Text>
                        </View>
                        {current?.url === item.url && <Check color="#34d399" size={20} />}
                    </TouchableOpacity>
                )}
            />
        </SafeAreaView>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1, backgroundColor: '#000', padding: 20 },
    header: { flexDirection: 'row', alignItems: 'center', marginBottom: 20 },
    title: { color: '#fff', fontSize: 20, fontWeight: 'bold', marginLeft: 16 },
    desc: { color: '#888', marginBottom: 16 },
    inputContainer: { flexDirection: 'row', marginBottom: 20 },
    input: {
        flex: 1, backgroundColor: '#1a1a1a', color: '#fff', borderRadius: 12,
        padding: 12, marginRight: 10, borderWidth: 1, borderColor: '#333'
    },
    addBtn: {
        backgroundColor: '#fff', width: 50, borderRadius: 12,
        alignItems: 'center', justifyContent: 'center'
    },
    item: {
        flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
        padding: 16, backgroundColor: '#111', borderRadius: 12, marginBottom: 10
    },
    activeItem: { borderColor: '#34d399', borderWidth: 1 },
    itemUrl: { color: '#fff', fontWeight: 'bold' },
    itemStatus: { color: '#666', fontSize: 12, marginTop: 4 }
});
