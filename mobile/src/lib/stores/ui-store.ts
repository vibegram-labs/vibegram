import { create } from 'zustand'

export type HomeEditAction = 'readAll' | 'read' | 'delete'

interface UIState {
    headerOpacity: number
    headerTranslateY: number
    isDrawerOpen: boolean
    isSettingsOpen: boolean
    isHistoryPanelOpen: boolean
    isModalOpen: boolean
    isHomeEditing: boolean
    homeEditSelectionCount: number
    homeEditActionRequestId: number
    homeEditAction: HomeEditAction | null
    setHeaderOpacity: (opacity: number) => void
    setHeaderTranslateY: (y: number) => void
    setDrawerOpen: (open: boolean) => void
    setSettingsOpen: (open: boolean) => void
    setHistoryPanelOpen: (open: boolean) => void
    setModalOpen: (open: boolean) => void
    setHomeEditing: (editing: boolean) => void
    setHomeEditSelectionCount: (count: number) => void
    requestHomeEditAction: (action: HomeEditAction) => void
}

export const useUIStore = create<UIState>((set) => ({
    headerOpacity: 1,
    headerTranslateY: 0,
    isDrawerOpen: false,
    isSettingsOpen: false,
    isHistoryPanelOpen: false,
    isModalOpen: false,
    isHomeEditing: false,
    homeEditSelectionCount: 0,
    homeEditActionRequestId: 0,
    homeEditAction: null,
    setHeaderOpacity: (headerOpacity) => set({ headerOpacity }),
    setHeaderTranslateY: (headerTranslateY) => set({ headerTranslateY }),
    setDrawerOpen: (isDrawerOpen) => set({ isDrawerOpen }),
    setSettingsOpen: (isSettingsOpen) => set({ isSettingsOpen }),
    setHistoryPanelOpen: (isHistoryPanelOpen) => set({ isHistoryPanelOpen }),
    setModalOpen: (isModalOpen) => set({ isModalOpen }),
    setHomeEditing: (isHomeEditing) => set({ isHomeEditing }),
    setHomeEditSelectionCount: (homeEditSelectionCount) => set({ homeEditSelectionCount }),
    requestHomeEditAction: (homeEditAction) =>
        set((state) => ({
            homeEditAction,
            homeEditActionRequestId: state.homeEditActionRequestId + 1,
        })),
}))
