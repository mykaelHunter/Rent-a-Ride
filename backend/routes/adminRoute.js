import express from "express"
import { adminAuth ,adminProfiile } from "../controllers/adminControllers/adminController.js"
import { signIn } from "../controllers/authController.js"
import { signOut  } from "../controllers/userControllers/userController.js"
import { addProduct, deleteVehicle, editVehicle,  } from "../controllers/adminControllers/dashboardController.js"
import { showVehicles } from "../controllers/adminControllers/dashboardController.js"
import { multerUploads } from "../utils/multer.js"
import { insertDummyData } from "../controllers/adminControllers/masterCollectionController.js"
import { getCarModelData } from "../controllers/adminControllers/masterCollectionController.js"
import { approveVendorVehicleRequest, fetchVendorVehilceRequests, rejectVendorVehicleRequest } from "../controllers/adminControllers/vendorVehilceRequests.js"
import { allBookings, changeStatus } from "../controllers/adminControllers/bookingsController.js"
import { verifyToken, requireAdmin } from "../utils/verifyUser.js"

const router = express.Router()

// INC-001 fix: every admin route below now requires a valid access/refresh
// token (verifyToken) AND an isAdmin user (requireAdmin) before it runs.
const adminOnly = [verifyToken, requireAdmin]

// Login check: verify the token belongs to an admin and report back.
router.post('/dashboard', ...adminOnly, adminAuth)
router.post('/profile', ...adminOnly, adminProfiile)
router.get('/signout', ...adminOnly, signOut)
router.post('/addProduct', ...adminOnly, multerUploads, addProduct)
router.get('/showVehicles', ...adminOnly, showVehicles)
router.delete('/deleteVehicle/:id', ...adminOnly, deleteVehicle)
router.put('/editVehicle/:id', ...adminOnly, editVehicle)
// INC-007 fix: dummy-data seeding is admin-only and no longer a bare GET
// that anyone could hit; still available for seeding but gated behind auth.
router.post('/dummyData', ...adminOnly, insertDummyData)
router.get('/getVehicleModels', ...adminOnly, getCarModelData)
router.get('/fetchVendorVehilceRequests', ...adminOnly, fetchVendorVehilceRequests)
router.post('/approveVendorVehicleRequest', ...adminOnly, approveVendorVehicleRequest)
router.post('/rejectVendorVehicleRequest', ...adminOnly, rejectVendorVehicleRequest)
router.get('/allBookings', ...adminOnly, allBookings)
router.post('/changeStatus', ...adminOnly, changeStatus)

export default router